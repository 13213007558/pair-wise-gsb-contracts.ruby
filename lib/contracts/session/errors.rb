# frozen_string_literal: true

module Contracts
  module Session
    class SessionError < StandardError
      attr_reader :side, :details

      def initialize(message = nil, side: nil, details: nil)
        @side = side
        @details = details
        super(message)
      end
    end

    class InvalidSessionType < SessionError
    end

    class DualityError < SessionError
    end

    class ProtocolViolation < SessionError
    end

    class MessageContractError < ParamContractError
      attr_reader :side

      def initialize(message, side:, data: {})
        data = data.merge(side: side, return_value: false)
        @side = side
        super(message, data)
      end
    end

    class WouldBlockError < SessionError
    end
  end
end
