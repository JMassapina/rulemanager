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

OPTIONS = OpenStruct.new
OPTIONS.config_file = '/etc/rulemanager.conf.yml'
OPTIONS.debug_mode = false
OPTIONS.piddir = '/var/run'
OPTIONS.pidfile = 'rulemanager.pid'
OPTIONS.logfile = '/var/log/rulemanager.log'

OptionParser.new do |opts|
  opts.banner = 'Usage: rulemanager.rb [options]'
  opts.on('-c', '--conf', 'Config file') do |c|
    OPTIONS.config_file = c
  end
  opts.on('-d', '--debug', "Debug mode - don't daemonize") do |d|
    OPTIONS.debug_mode = true
  end
  opts.on('-p', '--pidfile', 'Pidfile') do |p|
    OPTIONS.pidfile = p
  end
end.parse!

CONFIG = YAML.load(File.read(OPTIONS.config_file))

# ----- MAIN -----

logger = Logger.new(STDOUT)
logger.level = (STDOUT.tty? ? Logger::DEBUG : Logger::ERROR)
logger.info('rulemanager has started')
logger.info('detaching from tty, process %u' % Process.pid)

# Detach and daemonize

if DEBUG_MODE
  LOGGER = logger
else
  LOGGER = Logger.new(OPTIONS.logfile)
  LOGGER.level = (STDOUT.tty? ? Logger::DEBUG : Logger::INFO)

  if RUBY_VERSION < '1.9'
    exit if fork
    Process.setsid
    exit if fork
    Dir.chdir '/'
    STDIN.reopen '/dev/null'
    STDOUT.reopen '/dev/null', 'a'
    STDERR.reopen '/dev/null', 'a'
  else
    Process.daemon
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

  t = Thread.new { queue_poller }
  t.abort_on_exception = true

  EventMachine.run {
    if CONFIG['full_sync_enabled']
      EventMachine::PeriodicTimer.new(CONFIG['full_sync_every'].to_i) { full_sync }
    end
  }

rescue Lockfile::MaxTriesLockError
  LOGGER.warn('could not acquire lock (%s)' % CONFIG['lock_file'])
rescue Lockfile::StolenLockError
  LOGGER.fatal('lock was stolen, aborting (%s)' % CONFIG['lock_file'])
rescue Exception => msg
  puts msg
ensure
  exit unless lockfile.locked?
  LOGGER.debug('releasing lock')
  lockfile.unlock
end