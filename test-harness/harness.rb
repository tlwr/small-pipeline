#!/usr/bin/env ruby

require 'base64'
require 'English'
require 'fileutils'
require 'json'
require 'open3'
require 'optparse'

HarnessOptions = Struct.new(
  :cleanup,

  :directory,
  :dockerfile,

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

  def services?
    [
      self.rabbitmq, self.postgres, self.mysql, self.redis, self.elasticsearch,
    ].any?
  end

  def config(service)
    service_members = self.members.grep(/^#{service}/)
    self.to_h.select { |f, v| service_members.include? f }
  end
end

options = HarnessOptions.new

OptionParser.new do |p|
  p.on(
    '--[no-]cleanup',
    'Cleanup after finishing',
  ) { |v| options.cleanup = v }

  p.on(
    '--directory DIR',
    'Directory to build, this is ALWAYS relative',
  ) { |v| options.directory = v }

  p.on(
    '--dockerfile PATH',
    'Path to Dockerfile, this is ALWAYS relative; defaults to $DIR/Dockerfile',
  ) { |v| options.dockerfile = v }

  p.on(
    '--rabbitmq',
    'Enable RabbitMQ',
  ) { options.rabbitmq = true }
  p.on(
    '--rabbitmq-username USERNAME',
    'Username for RabbitMQ, default "harness"',
  ) { |v| options.rabbitmq_username = v }
  p.on(
    '--rabbitmq-password PASSWORD',
    'Password for RabbitMQ, default "harness"',
  ) { |v| options.rabbitmq_password = v }
  p.on(
    '--rabbitmq-direct-exchanges ex1,ex2,ex3', Array,
    'Direct exchanges for RabbitMQ, comma separated, default "direct1"',
  ) { |v| options.rabbitmq_direct_exchanges = v }
  p.on(
    '--rabbitmq-fanout-exchanges ex1,ex2,ex3', Array,
    'Fanout exchanges for RabbitMQ, comma separated, default "fanout1"',
  ) { |v| options.rabbitmq_fanout_exchanges = v }
  p.on(
    '--rabbitmq-topic-exchanges ex1,ex2,ex3', Array,
    'Topic exchanges for RabbitMQ, comma separated, default "topic1"',
  ) { |v| options.rabbitmq_topic_exchanges = v }
  p.on(
    '--rabbitmq-headers-exchanges ex1,ex2,ex3', Array,
    'Headers exchanges for RabbitMQ, comma separated, default "headers1"',
  ) { |v| options.rabbitmq_headers_exchanges = v }

  p.on(
    '--postgres',
    'Enable Postgres',
  ) { options.postgres = true }
  p.on(
    '--postgres-username USERNAME',
    'Username for Postgres, default "harness"',
  ) { |v| options.postgres_username = v }
  p.on(
    '--postgres-password PASSWORD',
    'Password for Postgres, default "harness"',
  ) { |v| options.postgres_password = v }
  p.on(
    '--postgres-databases db1,db2,db3', Array,
    'Databases for Postgres, comma separated, default "db1"',
  ) { |v| options.postgres_databases = v }

  p.on(
    '--mysql',
    'Enable MySQL',
  ) { options.mysql = true }
  p.on(
    '--mysql-username USERNAME',
    'Username for MySQL, default "harness"',
  ) { |v| options.mysql_username = v }
  p.on(
    '--mysql-password PASSWORD',
    'Password for MySQL, default "harness"',
  ) { |v| options.mysql_password = v }
  p.on(
    '--mysql-databases db1,db2,db3', Array,
    'Databases for MySQL, comma separated, default "db1"',
  ) { |v| options.mysql_databases = v }

  p.on('--redis', 'Enable redis') { options.redis = true }

  p.on(
    '--elasticsearch',
    'Enable Elasticsearch',
  ) { options.elasticsearch = true }
  p.on(
    '--elasticsearch-username USERNAME',
    'Username for Elasticsearch, default "harness"',
  ) { |v| options.elasticsearch_username = v }
  p.on(
    '--elasticsearch-password PASSWORD',
    'Password for Elasticsearch, default "harness"',
  ) { |v| options.elasticsearch_password = v }
  p.on(
    '--elasticsearch-indices ind1,ind2,ind3', Array,
    'Indices for Elasticsearch, comma separated, default "index1"',
  ) { |v| options.elasticsearch_indices = v }

  p.on('-h', '--help', 'Show help') do
    puts p.help
    exit
  end
end.parse!

if options.directory.nil?
  STDERR.puts 'Flag --directory is required'
  exit 1
end

directory = File.join(Dir.pwd, options.directory)

unless File.exist? directory
  STDERR.puts "Computed directory value #{directory} does not exsit"
  exit 1
end

dockerfile = options.dockerfile || File.join(directory, 'Dockerfile')

unless File.exist? dockerfile
  STDERR.puts "Computed Dockerfile value #{dockerfile} does not exsit"
  exit 1
end

STDERR.pp options

def podman_prelude
  'podman --root /podman --storage-driver vfs --cgroup-manager cgroupfs'
end

def buildah_prelude
  'buildah --root /podman --storage-driver vfs build-using-dockerfile'
end

def buildah_build(directory, dockerfile)
  STDERR.puts 'Building image (name: harness-test)'
  build_command = "#{buildah_prelude} --file '#{dockerfile}' --cap-add sys_admin --tag harness-test '#{directory}'"

  Process.wait(spawn(
    build_command,
    in: STDIN, out: STDOUT, err: STDERR,
  ))

  unless $CHILD_STATUS.success?
    STDERR.puts 'Failed to build image'
    exit $CHILD_STATUS.exitstatus
  end

  STDERR.puts 'Built image (name: harness-test)'
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

def configure_rabbitmq(pod_id, config)
  STDERR.puts "#{pod_id} | Configuring rabbitmq with #{config}"

  username = config[:rabbitmq_username]
  password = config[:rabbitmq_password]

  commands = [
    'sleep 15',
    "rabbitmqctl add_user '#{username}' '#{password}'",
    "rabbitmqctl set_permissions -p '/' '#{username}' '.*' '.*' '.*'",
  ].concat(
    config[:rabbitmq_direct_exchanges].map do |exchange|
      "rabbitmqadmin declare exchange name='#{exchange}' type=direct"
    end
  ).concat(
    config[:rabbitmq_fanout_exchanges].map do |exchange|
      "rabbitmqadmin declare exchange name='#{exchange}' type=fanout"
    end
  ).concat(
    config[:rabbitmq_topic_exchanges].map do |exchange|
      "rabbitmqadmin declare exchange name='#{exchange}' type=topic"
    end
  ).concat(
    config[:rabbitmq_headers_exchanges].map do |exchange|
      "rabbitmqadmin declare exchange name='#{exchange}' type=headers"
    end
  )

  commands.each do |command|
    exec_command = "#{podman_prelude} exec -it rabbitmq #{command}"
    STDERR.puts exec_command

    Process.wait(spawn(
      exec_command,
      in: STDIN, out: STDOUT, err: STDERR,
    ))

    unless $CHILD_STATUS.success?
      STDERR.puts "#{pod_id} | Failed to configure rabbitmq"
      exit $CHILD_STATUS.exitstatus
    end
  end

  STDERR.puts "#{pod_id} | Configured rabbitmq container"
end

buildah_build(directory, dockerfile)

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

STDERR.puts "Pod => #{pod_id}"

enable_rabbitmq(pod_id, '3.7-management') if options.rabbitmq
enable_postgres(pod_id, '9.6') if options.postgres
enable_mysql(pod_id, '8') if options.mysql
enable_redis(pod_id, '5.0.4') if options.redis
enable_elasticsearch(pod_id, '6.7.0') if options.elasticsearch

start_service(pod_id, 'rabbitmq') if options.rabbitmq
start_service(pod_id, 'postgres') if options.postgres
start_service(pod_id, 'mysql') if options.mysql
start_service(pod_id, 'redis') if options.redis
start_service(pod_id, 'elasticsearch') if options.elasticsearch

if options.services?
  STDERR.puts 'Waiting 10s for services to be started'
  sleep 10
end

configure_rabbitmq(pod_id, options.config('rabbitmq')) if options.rabbitmq
