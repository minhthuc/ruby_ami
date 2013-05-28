# encoding: utf-8

module RubyAMI
  class Lexer

    BufferOverrunError = Class.new IOError

    KILOBYTE = 1024
    BUFFER_SIZE = 128 * KILOBYTE unless defined? BUFFER_SIZE

    ##
    # IMPORTANT! See method documentation for adjust_pointers!
    #
    # @see  adjust_pointers
    #
    POINTERS = [
      :@current_pointer,
      :@token_start,
      :@token_end,
      :@version_start,
      :@event_name_start,
      :@current_key_position,
      :@current_value_position,
      :@last_seen_value_end,
      :@error_reason_start,
      :@follows_text_start,
      :@current_syntax_error_start,
      :@immediate_response_start
    ]


    
    attr_accessor :ami_version

    def initialize(delegate = nil)
      @delegate = delegate
      @data = ""
      @current_pointer = 0
      @ami_version = 0.0

	    @current_pointer ||= 0
	    @data_ending_pointer ||=   @data.length
	    @token_start = nil
	    @token_end = nil
    end

    def <<(new_data)
      extend_buffer_with new_data
      parse_buffer
    end

    def parse_buffer
      tokens = {
        cr: /\r/,
        lf: /\n/,
        crlf: /\r\n/,
        loose_newline: /\r?\n/,
        white: /[\t ]/,
        colon: /: */,
        stanza_break: /\r\n\r\n/,
        rest_of_line: /.*\r\n/,
        prompt: /Asterisk Call Manager\/(\d+\.\d+)\r\n/,
        key: /([[[:alnum:]][[:print:]]])[\r\n:]+/,
        keyvaluepair: /([[[:alnum:]][[:print:]]]+): *(.*)\r\n/,
        followsdelimiter: /\r?\n--END COMMAND--/,
        response: /response: */i,
        success: /response: *success\r\n/i,
        pong: /response: *pong\r\n/i,
        event: /event: *(.*)\r\n/i,
        error: /response: *error\r\n/i,
        follows: /response: *follows\r\n/i,
        followsbody: /(.*)?\r?\n--END COMMAND--/,

        
      }

      return unless @data =~ tokens[:stanza_break]

      @data.scan(/.*#{tokens[:stanza_break]}/).each do |msg|


    end

    def extend_buffer_with(new_data)
      length = new_data.size

      if length > BUFFER_SIZE
        raise Exception, "ERROR: Buffer overrun! Input size (#{new_data.size}) larger than buffer (#{BUFFER_SIZE})"
      end

      if length + @data.size > BUFFER_SIZE
        if @data.size != @current_pointer
          if @current_pointer < length
            # We are about to shift more bytes off the array than we have
            # parsed.  This will cause the parser to lose state so
            # integrity cannot be guaranteed.
            raise BufferOverrunError, "ERROR: Buffer overrun! AMI parser cannot guarantee sanity. New data size: #{new_data.size}; Current pointer at #{@current_pointer}; Data size: #{@data.size}"
          end
        end
        @data.slice! 0...length
        adjust_pointers -length
      end
      @data << new_data
      @data_ending_pointer = @data.size
    end

    protected

    ##
    # This method will adjust all pointers into the buffer according
    # to the supplied offset.  This is necessary any time the buffer
    # changes, for example when the sliding window is incremented forward
    # after new data is received.
    #
    # It is VERY IMPORTANT that when any additional pointers are defined
    # that they are added to this method.  Unpredictable results may
    # otherwise occur!
    #
    # @see https://adhearsion.lighthouseapp.com/projects/5871-adhearsion/tickets/72-ami-lexer-buffer-offset#ticket-72-26
    #
    # @param offset Adjust pointers by offset.  May be negative.
    #
    def adjust_pointers(offset)
      POINTERS.each do |ptr|
        value = instance_variable_get(ptr)
        instance_variable_set(ptr, value + offset) if !value.nil?
      end
    end

    ##
    # Called after a response or event has been successfully parsed.
    #
    # @param [Response, Event] message The message just received
    #
    def message_received(message)
      @delegate.message_received message
    end

    ##
    # Called when there is an Error: stanza on the socket. Could be caused by executing an unrecognized command, trying
    # to originate into an invalid priority, etc. Note: many errors' responses are actually tightly coupled to a
    # Event which comes directly after it. Often the message will say something like "Channel status
    # will follow".
    #
    # @param [String] reason The reason given in the Message: header for the error stanza.
    #
    def error_received(message)
      @delegate.error_received message
    end

    ##
    # Called when there's a syntax error on the socket. This doesn't happen as often as it should because, in many cases,
    # it's impossible to distinguish between a syntax error and an immediate packet.
    #
    # @param [String] ignored_chunk The offending text which caused the syntax error.
    def syntax_error_encountered(ignored_chunk)
      @delegate.syntax_error_encountered ignored_chunk
    end

    def init_success
      @current_message = Response.new
    end

    def init_response_follows
      @current_message = Response.new
    end

    def init_error
      @current_message = Error.new
    end

    def version_starts
      @version_start = @current_pointer
    end

    def version_stops
      self.ami_version = @data[@version_start...@current_pointer].to_f
      @version_start = nil
    end

    def event_name_starts
      @event_name_start = @current_pointer
    end

    def event_name_stops
      event_name = @data[@event_name_start...@current_pointer]
      @event_name_start = nil
      @current_message = Event.new(event_name)
    end

    def key_starts
      @current_key_position = @current_pointer
    end

    def key_stops
      @current_key = @data[@current_key_position...@current_pointer]
    end

    def value_starts
      @current_value_position = @current_pointer
    end

    def value_stops
      @current_value = @data[@current_value_position...@current_pointer]
      @last_seen_value_end = @current_pointer + 2 # 2 for \r\n
      add_pair_to_current_message
    end

    def error_reason_starts
      @error_reason_start = @current_pointer
    end

    def error_reason_stops
      @current_message.message = @data[@error_reason_start...@current_pointer]
    end

    def follows_text_starts
      @follows_text_start = @current_pointer
    end

    def follows_text_stops
      text = @data[@last_seen_value_end..@current_pointer]
      text.sub! /\r?\n--END COMMAND--/, ""
      @current_message.text_body = text
      @follows_text_start = nil
    end

    def add_pair_to_current_message
      @current_message[@current_key] = @current_value
      reset_key_and_value_positions
    end

    def reset_key_and_value_positions
      @current_key, @current_value, @current_key_position, @current_value_position = nil
    end

    def syntax_error_starts
      @current_syntax_error_start = @current_pointer # Adding 1 since the pointer is still set to the last successful match
    end

    def syntax_error_stops
      # Subtracting 3 from @current_pointer below for "\r\n" which separates a stanza
      offending_data = @data[@current_syntax_error_start...@current_pointer - 1]
      syntax_error_encountered offending_data
      @current_syntax_error_start = nil
    end

    def immediate_response_starts
      @immediate_response_start = @current_pointer
    end

    def immediate_response_stops
      message = @data[@immediate_response_start...(@current_pointer -1)]
      message_received Response.from_immediate_response(message)
    end

    ##
    # This method is used primarily in debugging.
    #
    def view_buffer(message = nil)
      message ||= "Viewing the buffer"

      buffer = @data.clone
      buffer.insert(@current_pointer, "\033[0;31m\033[1;31m^\033[0m")

      buffer.gsub!("\r", "\\\\r")
      buffer.gsub!("\n", "\\n\n")

      puts <<-INSPECTION
VVVVVVVVVVVVVVVVVVVVVVVVVVVVV
####  #{message}
#############################
#{buffer}
#############################
^^^^^^^^^^^^^^^^^^^^^^^^^^^^^
      INSPECTION
    end
  end
end

