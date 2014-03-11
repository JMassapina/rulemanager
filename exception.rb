module RuleManager
    module Error
      class Standard < StandardError; end

      class MalformedMessage < Standard
        def message
          'The message appears to be either invalid JSON, or not base64 encoded'
        end
      end

      class FieldsMissing < Standard
        def message
          'The message is missing required fields'
        end
      end

      class NotAHash < Standard
        def message
          'The message does not appear to contain a hash'
        end
      end
    end
end
