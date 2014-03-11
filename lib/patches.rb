# ----- OVERRIDES -------------------------------------------------------------------
# The ASAs don't support SSH properly. We need to disable certain checks, otherwise this
# script almost always fails to connect.

module Net; module SSH; module Transport; module PacketStream
  def next_packet(mode=:nonblock)
    case mode
      when :nonblock then
        if available_for_read?
          if fill <= 0
            #           raise Net::SSH::Disconnect, "connection closed by remote host"
          end
        end
        poll_next_packet

      when :block then
        loop do
          packet = poll_next_packet
          return packet if packet

          loop do
            result = Net::SSH::Compat.io_select([self])
            (break if result.first.any?) if result
          end

          if fill <= 0
            #           raise Net::SSH::Disconnect, "connection closed by remote host"
          end
        end

      else
        raise ArgumentError, "expected :block or :nonblock, got #{mode.inspect}"
    end
  end
end end end end