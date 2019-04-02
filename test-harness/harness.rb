#!/usr/bin/env ruby

require 'English'
require 'fileutils'
require 'open3'
require 'optparse'

HarnessOptions = Struct.new(
  :cleanup,

  :rabbitmq,
  :rabbitmq_username, :rabbitmq_password,
  :rabbitmq_direct_exchanges, :rabbitmq_fanout_exchanges,
  :rabbitmq_topic_exchanges, :rabbitmq_headers_exchanges,

  :postgres,
  :postgres_username, :postgres_password, :postgres_databases,

  :mysql,
  :mysql_username, :mysql_password, :mysql_databases,

  :redis,

  :elasticsearch,
  :elasticsearch_username, :elasticsearch_password,
  :elasticsearch_indices,

  keyword_init: true,
) do

  def initialize(*)
    super

    set_option_defaults
    set_rabbitmq_defaults
    set_postgres_defaults
    set_mysql_defaults
    set_redis_defaults
    set_elasticsearch_defaults
  end

  def set_option_defaults
    self.cleanup ||= true
  end

  def set_rabbitmq_defaults
    self.rabbitmq                    ||= false
    self.rabbitmq_username           ||= 'harness'
    self.rabbitmq_password           ||= 'harness'
    self.rabbitmq_direct_exchanges   ||= ['direct1']
    self.rabbitmq_fanout_exchanges   ||= ['fanout']
    self.rabbitmq_topic_exchanges    ||= ['topic1']
    self.rabbitmq_headers_exchanges  ||= ['headers1']
  end

  def set_postgres_defaults
    self.postgres           ||= false
    self.postgres_username  ||= 'harness'
    self.postgres_password  ||= 'harness'
    self.postgres_databases ||= ['db1']
  end

  def set_mysql_defaults
    self.mysql           ||= false
    self.mysql_username  ||= 'harness'
    self.mysql_password  ||= 'harness'
    self.mysql_databases ||= ['db1']
  end

  def set_redis_defaults
    self.redis ||= false
  end

  def set_elasticsearch_defaults
    self.elasticsearch          ||= false
    self.elasticsearch_username ||= 'harness'
    self.elasticsearch_password ||= 'harness'
    self.elasticsearch_indices  ||= ['index1']
  end
end

options = HarnessOptions.new

OptionParser.new do |p|
  p.on(
    '--[no-]cleanup',
    'Cleanup after finishing',
  ) { |v| options.cleanup = v }

  p.on(
    '--rabbitmq',
    'Enable RabbitMQ',
  ) { options.rabbitmq = true }
  p.on(
    '--rabbitmq-username',
    'Username for RabbitMQ, default "harness"',
  ) { |v| options.rabbitmq_username = v }
  p.on(
    '--rabbitmq-password',
    'Password for RabbitMQ, default "harness"',
  ) { |v| options.rabbitmq_password = v }
  p.on(
    '--rabbitmq-direct-exchanges',
    'Direct exchanges for RabbitMQ, comma separated, default "direct1"',
  ) { |v| options.rabbitmq_direct_exchanges = v.split(',') }
  p.on(
    '--rabbitmq-fanout-exchanges',
    'Fanout exchanges for RabbitMQ, comma separated, default "fanout1"',
  ) { |v| options.rabbitmq_fanout_exchanges = v.split(',') }
  p.on(
    '--rabbitmq-topic-exchanges',
    'Topic exchanges for RabbitMQ, comma separated, default "topic1"',
  ) { |v| options.rabbitmq_topic_exchanges = v.split(',') }
  p.on(
    '--rabbitmq-headers-exchanges',
    'Headers exchanges for RabbitMQ, comma separated, default "headers1"',
  ) { |v| options.rabbitmq_headers_exchanges = v.split(',') }

  p.on(
    '--postgres',
    'Enable Postgres',
  ) { options.postgres = true }
  p.on(
    '--postgres-username',
    'Username for Postgres, default "harness"',
  ) { |v| options.postgres_username = v }
  p.on(
    '--postgres-password',
    'Password for Postgres, default "harness"',
  ) { |v| options.postgres_password = v }
  p.on(
    '--postgres-databases',
    'Databases for Postgres, comma separated, default "db1"',
  ) { |v| options.postgres_databases = v.split(',') }

  p.on(
    '--mysql',
    'Enable MySQL',
  ) { options.mysql = true }
  p.on(
    '--mysql-username',
    'Username for MySQL, default "harness"',
  ) { |v| options.mysql_username = v }
  p.on(
    '--mysql-password',
    'Password for MySQL, default "harness"',
  ) { |v| options.mysql_password = v }
  p.on(
    '--mysql-databases',
    'Databases for MySQL, comma separated, default "db1"',
  ) { |v| options.mysql_databases = v.split(',') }

  p.on('--redis', 'Enable redis') { options.redis = true }

  p.on(
    '--elasticsearch',
    'Enable Elasticsearch',
  ) { options.elasticsearch = true }
  p.on(
    '--elasticsearch-username',
    'Username for Elasticsearch, default "harness"',
  ) { |v| options.elasticsearch_username = v }
  p.on(
    '--elasticsearch-password',
    'Password for Elasticsearch, default "harness"',
  ) { |v| options.elasticsearch_password = v }
  p.on(
    '--elasticsearch-indices',
    'Indices for Elasticsearch, comma separated, default "index1"',
  ) { |v| options.elasticsearch_indices = v.split(',') }

  p.on('-h', '--help', 'Show help') do
    puts p.help
    exit
  end
end.parse!

puts options

def podman_prelude
  'podman --root /podman --storage-driver vfs --cgroup-manager cgroupfs'
end

def podman_setup
  FileUtils.mkdir_p '/podman'

  output, status = Open3.capture2e("#{podman_prelude} pod create")

  unless status.success?
    STDERR.puts 'Failed to set up podman:', status, output
    exit status.exitstatus
  end

  pod_id = output.chomp
  pod_id
end

def enable_harness_service(pod_id, name, version, port, env_vars={})
  STDERR.puts "#{pod_id} | Creating #{name} with version #{version} on #{port}"

  env_vars_cmd_frag = env_vars.map { |k, v| "-e '#{k}=#{v}'" }.join(' ')

  create_command = %W[
    #{podman_prelude} create

    --pod    '#{pod_id}'
    --expose '#{port}'
    --name   '#{name}'
    #{env_vars_cmd_frag}

    '#{name}:#{version}'
  ].join(' ')

  Process.wait(spawn(
    create_command,
    in: STDIN, out: STDOUT, err: STDERR,
  ))

  unless $CHILD_STATUS.success?
    STDERR.puts "#{pod_id} | Failed to enable #{name}"
    exit $CHILD_STATUS.exitstatus
  end

  STDERR.puts "#{pod_id} | Created #{name} container"
end

def start_service(pod_id, name)
  STDERR.puts "#{pod_id} | Starting #{name}"

  start_command = %W[
    #{podman_prelude} start '#{name}'
  ].join(' ')

  Process.wait(spawn(
    start_command,
    in: STDIN, out: STDOUT, err: STDERR,
  ))

  unless $CHILD_STATUS.success?
    STDERR.puts "#{pod_id} | Failed to start #{name}"
    exit $CHILD_STATUS.exitstatus
  end

  STDERR.puts "#{pod_id} | Started #{name} container"
end

def enable_rabbitmq(pod_id, rabbitmq_version)
  enable_harness_service(pod_id, 'rabbitmq', rabbitmq_version, 5672)
end

def enable_postgres(pod_id, postgres_version)
  enable_harness_service(pod_id, 'postgres', postgres_version, 5432)
end

def enable_mysql(pod_id, mysql_version)
  env_vars = { 'MYSQL_ROOT_PASSWORD' => 'root' }
  enable_harness_service(pod_id, 'mysql', mysql_version, 3306, env_vars)
end

def enable_redis(pod_id, redis_version)
  enable_harness_service(pod_id, 'redis', redis_version, 6379)
end

def enable_elasticsearch(pod_id, elasticsearch_version)
  enable_harness_service(pod_id, 'elasticsearch', elasticsearch_version, 3306)
end

pod_id = podman_setup

if options.cleanup
  Signal.trap('EXIT') do
    STDERR.puts "#{pod_id} | Killing pod"

    Process.wait(spawn(
      "#{podman_prelude} pod kill '#{pod_id}'",
      in: STDIN, out: STDOUT, err: STDERR,
    ))
    unless $CHILD_STATUS.success?
      STDERR.puts "#{pod_id} | Failed to kill pod"
      exit status.exitstatus
    end

    STDERR.puts "#{pod_id} | Removing pod"
    Process.wait(spawn(
      "#{podman_prelude} pod rm --force '#{pod_id}'",
      in: STDIN, out: STDOUT, err: STDERR,
    ))
    unless $CHILD_STATUS.success?
      STDERR.puts "#{pod_id} | Failed to remove pod"
      exit status.exitstatus
    end
  end
end

puts "Pod => #{pod_id}"

enable_rabbitmq(pod_id, '3.7') if options.rabbitmq
enable_postgres(pod_id, '9.6') if options.postgres
enable_mysql(pod_id, '8') if options.mysql
enable_redis(pod_id, '5.0.4') if options.redis
enable_elasticsearch(pod_id, '6.7.0') if options.elasticsearch

start_service(pod_id, 'redis') if options.redis
