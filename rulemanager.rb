#!/usr/bin/ruby

require 'rubygems'
require 'lockfile'
require 'cisco'
require 'aws-sdk'
require 'net/https'
require 'addressable/uri'
require 'uri'
require 'hashery'
require 'logger'
require 'logger/colors' if STDOUT.tty?
require 'optparse'
require 'eventmachine'
require 'pidfile'
require 'base64'
require 'json'
require 'daemons'
require 'socket'
require 'yaml'
require 'pp'

Dir[File.dirname(__FILE__) + '/lib/*.rb'].each {|file| require File.expand_path(file) }
include RuleManager

OPTIONS = OpenStruct.new
OPTIONS.config_file = '/etc/rulemanager.conf.yml'
OPTIONS.debug_mode = false
OPTIONS.piddir = '/var/run'
OPTIONS.pidfile = 'rulemanager.pid'
OPTIONS.logfile = '/var/log/rulemanager.log'

OptionParser.new do |opts|
  opts.banner = 'Usage: rulemanager.rb [options]'
  opts.on('--conf configfile', String, 'Config file') do |configfile|
    OPTIONS.config_file = configfile
  end
  opts.on('-d', '--debug', "Debug mode - don't daemonize") do |d|
    OPTIONS.debug_mode = true
  end
  opts.on('-p', '--pidfile pidfile', 'Pidfile') do |pidfile|
    OPTIONS.pidfile = pidfile
  end
  opts.on('-p', '--piddir piddir', 'Pid directory') do |piddir|
    OPTIONS.piddir = piddir
  end
  opts.on('-p', '--logfile logfile', 'Logfile') do |logfile|
    OPTIONS.logfile = logfile
  end
end.parse!

CONFIG = YAML.load(File.read(OPTIONS.config_file))

# ----- MAIN -----

logger = Logger.new(STDOUT)
logger.level = (STDOUT.tty? ? Logger::DEBUG : Logger::ERROR)
logger.info('rulemanager has started')

# Detach and daemonize

if OPTIONS.debug_mode
  LOGGER = logger
else
  logger.info('detaching from tty, process %u' % Process.pid)
  LOGGER = Logger.new(OPTIONS.logfile)
  LOGGER.level = Logger::DEBUG

  if RUBY_VERSION < '1.9'
    exit if fork
    Process.setsid
    exit if fork
    Dir.chdir '/tmp'
    STDIN.reopen '/dev/null'
    STDOUT.reopen '/dev/null', 'a'
    STDERR.reopen '/dev/null', 'a'
  else
    Process.daemon(true)
  end
end

KEYS = Hashery::IniHash.new(CONFIG['accounts_file']) rescue
    LOGGER.fatal('init: could not read from %s' % CONFIG['accounts_file'])

PidFile.new(:piddir => OPTIONS.piddir, :pidfile => OPTIONS.pidfile)

begin
  lockfile = Lockfile.new(CONFIG['lock_file'], :retries => 1)
  if CONFIG['full_sync_enabled']
    LOGGER.info("running full sync every #{CONFIG['full_sync_every']} seconds")
  end

  if CONFIG['sqs_enabled']
    t = Thread.new { RuleManager.queue_poller }
    t.abort_on_exception = true
  end

  if CONFIG['full_sync_enabled']
    if CONFIG['initial_sync']
      RuleManager.full_sync
    end

    EventMachine.run {
        EventMachine::PeriodicTimer.new(CONFIG['full_sync_every'].to_i) { RuleManager.full_sync }
    }
  end

rescue Lockfile::MaxTriesLockError
  LOGGER.warn('could not acquire lock (%s)' % CONFIG['lock_file'])
  exit 1
rescue Lockfile::StolenLockError
  LOGGER.fatal('lock was stolen, aborting (%s)' % CONFIG['lock_file'])
  exit 1
rescue Exception => msg
  puts msg
  exit 1
ensure
  exit unless lockfile.locked?
  LOGGER.debug('releasing lock')
  lockfile.unlock
end
