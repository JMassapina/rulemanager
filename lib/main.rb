module RuleManager
  def read_cache
    LOGGER.debug('reading cache')
    begin
      #noinspection RubyResolve
      cache_hosts = Marshal.load(File.read(CONFIG['cache_file']))
      LOGGER.info('cache contains %u entries' % cache_hosts.count)
    rescue
      LOGGER.warn('cache file not found - creating a new one')
      cache_hosts = []
    end
    cache_hosts
  end

  def get_instances
    aws_hosts = []
    KEYS.each do |thiskey|
      instance_count = 0
      regions = thiskey[1]['regions'].split(/,\s*/).collect { |a| a[/[\w\-]+/] }
      regions.each do |thisregion|
        begin
          ec2 = AWS::EC2.new( :secret_access_key => thiskey[1]['aws_secret_access_key'],
                  :access_key_id => thiskey[1]['aws_access_key_id'],
                  :region => thisregion)
          ec2.instances.each { |instance| aws_hosts << instance.ip_address; instance_count += 1 }
        rescue
          LOGGER.error('aws: could not get instance list for %s, region %s' % [ thiskey[0], thisregion ] )
        end
      end
      LOGGER.info('found %u instance%s in %u region%s for %s' % [instance_count, (instance_count == 1 ? '' : 's'), regions.count, (regions.count == 1 ? '' : 's'), thiskey[0]])
    end

    aws_hosts.reject! { |c| c.to_s.empty? }
    aws_hosts.sort
  end

  def write_cache(aws_hosts)
    LOGGER.debug('writing cache')
    File.open(CONFIG['cache_file'], 'wb') do |f|
      f.write Marshal.dump(aws_hosts) rescue
        LOGGER.fatal('could not write to cache file!')
    end
  end

  def add_to_cache(node_ip)
    cache = read_cache
    cache << node_ip
    write_cache(cache)
  end

  def update_single_node(instance_id, region, owner)
    begin
      region = region[0..-2]
      ec2 = AWS::EC2.new( :secret_access_key => KEYS[CONFIG['owner_map'][owner.to_i]]['aws_secret_access_key'],
        :access_key_id => KEYS[CONFIG['owner_map'][owner.to_i]]['aws_access_key_id'],
        :region => region)
      node_ip = ec2.instances[instance_id].ip_address
      CONFIG['devices'].each do |hostname|
        asa = device_connect(hostname)
        LOGGER.info('updating config on %s' % hostname)
        exec_config(asa, ['network-object host %s' % node_ip ])
      end
      add_to_cache(node_ip)
    rescue AWS::Core::Resource::NotFound
      LOGGER.error('could not get info for instance %s (not found)' % instance_id)
    rescue => exception
      LOGGER.error('error processing message, dropped: %s' % exception.message)
    end
  end

  def hipchat_notify_success(message)
    options = {
        :room_id => CONFIG['hipchat_room_id'],
        :from => 'rulemanager',
        :message_format => 'html',
        :color => 'green',
        :message => message
    }

    query = Addressable::URI.new
    query.query_values = options
    uri = URI.parse(CONFIG['hipchat_url'])

    LOGGER.info('posting to hipchat' % uri.request_uri)

    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = true

    http.verify_mode = OpenSSL::SSL::VERIFY_NONE
    http.start do |this|
      response = this.request_post(uri.request_uri, query.query)
      LOGGER.warn('could not send notification to hipchat') unless response.kind_of? Net::HTTPOK
      LOGGER.debug(response)
    end
  end

  def full_sync
    LOGGER.debug('grabbing lock')
    keys = KEYS

    LOGGER.info('retrieving instance information for %u account%s' % [ keys.count, (keys.count == 1 ? '' : 's') ])

    aws_hosts = get_instances
    hosts_read_from_cache = read_cache
    new_aws_hosts = aws_hosts - hosts_read_from_cache
    removed_aws_hosts = hosts_read_from_cache - aws_hosts

    if new_aws_hosts.count + removed_aws_hosts.count == 0
      LOGGER.info('no changes to be made')
      return true
    end

    CONFIG['devices'].each do |device_ip|

      asa = device_connect(device_ip)
      LOGGER.info('connected to %s, getting configuration' % device_ip)

      firewalled_hosts = get_object_group(asa, CONFIG['object_group'])
      new_firewalled_hosts = aws_hosts - firewalled_hosts
      removed_firewalled_hosts = firewalled_hosts - aws_hosts

      if firewalled_hosts != hosts_read_from_cache
        LOGGER.warn('cache is inconsistent with live data from device')
      end

      if new_firewalled_hosts.count + removed_firewalled_hosts.count == 0
        LOGGER.warn('cache suggested changes required, but device is already up-to-date')
        LOGGER.info('no changes to be made')
        next
      end

      if removed_firewalled_hosts.count > 0
        LOGGER.info('removing %u old host%s from object-group' %
                        [ removed_firewalled_hosts.count, (removed_firewalled_hosts.count == 1 ? '' : 's') ])
      else
        LOGGER.info('no old hosts to remove')
      end
      exec_config(asa, removed_firewalled_hosts.collect{ |h| 'no network-object host %s' % h })

      if new_firewalled_hosts.count > 0
        LOGGER.info('adding %u new host%s from object-group' %
                        [ new_firewalled_hosts.count, (new_firewalled_hosts.count == 1 ? '' : 's') ])
      else
        LOGGER.info('no new hosts to be added')
      end

      exec_config(asa, new_firewalled_hosts.collect{ |h| 'network-object host %s' % h })

      LOGGER.info('changes complete, verifying configuration')
      device_hosts = get_object_group(asa, CONFIG['object_group']).sort

      diff = aws_hosts - device_hosts

      if diff.count > 0
        LOGGER.error('object in running-config does not match expected content after update')
        return false
      end

      if aws_hosts != device_hosts
        LOGGER.warn('extra objects in object-group, but all aws hosts are included')
      end

      LOGGER.info('all done for %s' % device_ip)
    end

    write_cache(aws_hosts)
    LOGGER.info('operation complete')
  end

  def queue_poller
    AWS.config(:access_key_id => CONFIG['sqs_creds']['aws_access_key_id'], :secret_access_key => CONFIG['sqs_creds']['aws_secret_access_key'], :region => CONFIG['sqs_region'] )
    sqs = AWS::SQS::Queue.new(CONFIG['sqs_url'])
    LOGGER.info("polling SQS queue #{CONFIG['sqs_url']}")
    sqs.poll do |msg|
      begin
        msg_h = JSON.parse(Base64.decode64(msg.body)) or raise RuleManager::Error::MalformedMessage
        msg_h.is_a?(Hash) or raise RuleManager::Error::NotAHash
        %w(hostname, instance_id, state, owner, region).each { |k| raise RuleManager::Error::FieldsMissing unless msg_h.has_key?(k) }

        LOGGER.info('node %s (%s) sent %s notification' % [ msg_h['hostname'], msg_h['instance_id'], msg_h['state'] ])
        case msg_h['state']
        when 'up'
          LOGGER.debug(msg_h)
          update_single_node(msg_h['instance_id'], msg_h['region'], msg_h['owner'])
          if CONFIG['hipchat_enabled']
            hipchat_notify_success('Added %s: [%s] (by %s)' % [ msg_h['instance_id'], msg_h['hostname'], Socket.gethostname ])
          end
        else

        end
      rescue RuleManager::Error::Standard => exception
        LOGGER.warn(exception.message)
      end
    end
  end
end