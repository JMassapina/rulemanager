module RuleManager
    def exec_config(asa, confarray)
      slices = 0
      confarray.each_slice(50) do |slice|
        safe_execute do
          asa.run do |x|
            x.enable(CONFIG['device_enable'])
            x.cmd('configure terminal')
            x.cmd('object-group network %s' % CONFIG['object_group'])
            slice.each do |thisline|
              x.cmd(thisline)
              LOGGER.debug('exec: %s' % thisline)
            end
          end
        end
        slices += 1
        LOGGER.debug('command slice %u of %u sent' % [ slices, (confarray.count / 50.0).ceil ])
        end
      debug
    end

    def resolve_objects(source, asa)
      LOGGER.info('retrieving names')
      names = get_names(asa)
      LOGGER.info('retrieving objects')
      objects = get_objects(asa)
      LOGGER.debug('loaded %u names and %u objects' % [ names.count, objects.count ])
      resolved = source
      source.each do |thishost|
        this_object = objects.select { |objname, ip| objname == thishost and ip[/^[0-9.]+$/] }.first
        this_object ||= names.select { |objname, ip| objname == thishost and ip[/^[0-9.]+$/] }.first

        unless this_object.nil?
          resolved << this_object[1]
          resolved.delete(this_object[0])
          LOGGER.info('device aliases %s as object/name %s' % [ this_object[1], thishost ])
        end
      end
      resolved
    end

    def get_objects(asa)
      safe_execute do
        output = asa.run do |x|
          x.enable(CONFIG['device_enable'])
          x.cmd('terminal pager 0')
          x.cmd('show run object network')
        end
      end

      begin
        objects = output.join.scan(/object network ([a-zA-Z0-9_\-]+)\n\s+host\s+([a-zA-Z0-9_\-.]+)/)
      rescue
        LOGGER.fatal('could not read object list from device')
        exit
      end
      objects
    end

    def get_object_group(asa, object_group)
      safe_execute do
        output = asa.run do |x|
          LOGGER.debug('enable')
          x.enable(CONFIG['device_enable'])
          x.cmd('terminal pager 0')
          x.cmd('show object-group')
        end
      end

      begin
        object_group_list = output.join.scan(/object-group network ([a-zA-Z0-9_\-]+)\n((?:\s[a-zA-Z0-9\-_. ]+\n?)+)/)
        target_group_objects = object_group_list.select{ |x| x[0] == object_group}.first[1]
        asa_hosts = target_group_objects.scan(/network-object host ([a-zA-Z0-9_.\-]+)\n/).collect { |a| a.first }
      rescue
        LOGGER.fatal('could not read object-group from device - does it exist?')
        exit
      end
      resolve_objects(asa_hosts, asa)
    end

    def get_names(asa)
      safe_execute do
        output = asa.run do |x|
          x.enable(CONFIG['device_enable'])
          x.cmd('terminal pager 0')
          x.cmd('show run names')
        end
      end

      begin
        names = output.join.scan(/name\s+([0-9.]+)\s+([a-zA-Z0-9\.\-_]+)/)
      rescue
        LOGGER.fatal('could not read name list from device')
        exit
      end

      # Names in Cisco land are IP first, host last. Grumble grumble.
      names.collect {|n| [ n[1], n[0] ] }
    end

    def device_connect(device_ip, timeout=10)
      Cisco::Base.new( :directargs => [ device_ip, CONFIG['device_user'], {
          :password => CONFIG['device_password'],
          :auth_methods => ['password'],
          :verbose => :warn,
          :timeout => timeout
      } ], :transport => 'ssh')
    end

    def safe_execute
     attempts_left = CONFIG['max_attempts']
     begin
        yield
      rescue Net::SSH::Disconnect => e
        attempts_left -= 1
        if attempts_left > 0
          LOGGER.warn('abruptly disconnected from device, reconnecting (attempt %u of %u)'  % [ (CONFIG['max_attempts'] - attempts_left), CONFIG['max_attempts'] ])
          LOGGER.debug('ssh: %s' % e.message)
          retry
        else
          LOGGER.fatal('too many connection failures - aborting')
          exit
        end
      rescue Timeout::Error => e
        attempts_left -= 1
        if attempts_left > 0
          LOGGER.warn('execution expired, retrying (attempt %u of %u)' % [ (CONFIG['max_attempts'] - attempts_left), CONFIG['max_attempts'] ] )
          LOGGER.debug('ssh execution expired: %s' % e.message)
          retry
        else
          LOGGER.fatal('unable to get object group and too many failures, aborting' % CONFIG['max_attempts'])
          exit
        end
      rescue Cisco::CiscoError => e
        LOGGER.fatal('error from device: %s' % e.message)
        exit
      end
    end
end
