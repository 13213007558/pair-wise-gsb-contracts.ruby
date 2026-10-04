# frozen_string_literal: true

module Contracts
  module Session
    Message = Struct.new(:payload, keyword_init: true)
    BranchSelection = Struct.new(:label, keyword_init: true)

    class MemoryQueue
      def initialize
        @messages = []
      end

      def push(message)
        @messages.push(message)
        self
      end

      def pop
        @messages.shift
      end

      def empty?
        @messages.empty?
      end
    end

    class Endpoint
      attr_reader :side, :type, :state, :frames, :inbound, :outbound

      def initialize(type, inbound:, outbound:, side:)
        @type = type
        @inbound = inbound
        @outbound = outbound
        @side = side.to_sym
        @frames = {}
        @recursion_ids = {}
        @local_recursion_types = {}
        @closed = false
        @state = enter(localize(type))
      end

      def send!(payload)
        assert_open!
        expect_action!(SendType)
        validate_payload!(payload, state.contract, side)

        outbound.push(Message.new(payload: payload))
        advance(state.continuation)
        payload
      end

      def receive!
        assert_open!
        expect_action!(ReceiveType)

        message = pop_message!
        unless message.is_a?(Message)
          raise violation("expected a message but received #{message.class}", other_side)
        end

        validate_payload!(message.payload, state.contract, other_side)
        advance(state.continuation)
        message.payload
      end

      def select!(label)
        assert_open!
        expect_action!(SelectType)

        normalized_label = normalize_branch_label(label, side)
        unless state.labels.include?(normalized_label)
          raise violation(unknown_branch_message(normalized_label), side)
        end

        outbound.push(BranchSelection.new(label: normalized_label))
        advance(state[normalized_label])
        normalized_label
      end

      def offer!(expected_label = nil)
        assert_open!
        expect_action!(OfferType)

        if expected_label
          normalized_expected = normalize_branch_label(expected_label, side)
          unless state.labels.include?(normalized_expected)
            raise violation(unknown_branch_message(normalized_expected), side)
          end
        end

        message = pop_message!
        unless message.is_a?(BranchSelection)
          raise violation("expected a branch selection but received #{message.class}", other_side)
        end

        label = normalize_branch_label(message.label, other_side)
        unless state.labels.include?(label)
          raise violation(unknown_branch_message(label), other_side)
        end

        advance(state[label])
        label
      end

      def close!
        assert_open!
        unless state.is_a?(EndType)
          raise violation("closed before the protocol reached End", side)
        end

        @closed = true
        true
      end

      def closed?
        @closed
      end

      private

      attr_reader :recursion_ids

      def assert_open!
        return unless closed?

        raise violation("operated on a closed endpoint", side)
      end

      def expect_action!(klass)
        return if state.is_a?(klass)

        expected = action_name(klass)
        actual = action_name(state.class)
        raise violation("#{side} endpoint expected #{expected} but protocol is at #{actual}", side)
      end

      def validate_payload!(payload, contract, violating_side)
        return if Contract.valid?(payload, contract)

        raise MessageContractError.new(
          "#{violating_side} endpoint violated message contract: " \
            "#{payload.inspect} does not satisfy #{contract.inspect}",
          side: violating_side,
          data: { arg: payload, contract: contract },
        )
      end

      def pop_message!
        message = inbound.pop
        return message unless message.nil?

        raise WouldBlockError.new(
          "no message is available for #{side} endpoint",
          side: side,
        )
      end

      def advance(continuation)
        @state = enter(localize(continuation))
      end

      def enter(type)
        case type
        when RecursionType
          frame = frames[type.runtime_id] ||= { state: enter(type.body), type: type }
          frame[:state]
        when RecursionVariable
          frame = frames[type.identity]
          recursion = @local_recursion_types[type.identity] if frame.nil?
          return enter(recursion) if recursion

          if frame.nil? && !frames.key?(type.identity)
            raise violation("uses recursion state #{type.name.inspect} before entering it", side)
          end

          enter(frame[:type])
        else
          type
        end
      end

      def localize(type)
        case type
        when SendType, ReceiveType
          type.class.new(type.contract, localize(type.continuation))
        when SelectType, OfferType
          type.class.new(type.branches.map { |branch| localize_branch(branch) })
        when RecursionType
          localize_recursion(type)
        when RecursionVariable
          type.target ? RecursionVariable.new(type.name, local_id(type.identity)) : type
        else
          type
        end
      end

      def localize_branch(branch)
        Branch.new(branch.label, localize(branch.continuation))
      end

      def localize_recursion(type)
        local_identity = recursion_ids[type.runtime_id] ||= object_id_for(type)
        localized = RecursionType.new(type.name, End, local_identity)
        @local_recursion_types[local_identity] = localized
        localized.body = localize(type.body)
        localized
      end

      def local_id(identity)
        return identity if @local_recursion_types.key?(identity)

        recursion_ids.fetch(identity) do
          raise violation("uses recursion state #{identity.inspect} from another session", side)
        end
      end

      def object_id_for(type)
        @local_recursion_counter ||= 0
        @local_recursion_counter += 1
        [side, @local_recursion_counter, object_id].hash
      end

      def unknown_branch_message(label)
        "selected unknown branch #{label.inspect}; valid branches are #{state.labels.inspect}"
      end

      def normalize_branch_label(label, violating_side)
        return label.to_sym if label.is_a?(Symbol) || label.is_a?(String)

        raise violation("branch label #{label.inspect} must be a Symbol or String", violating_side)
      end

      def violation(message, violating_side)
        ProtocolViolation.new(message, side: violating_side)
      end

      def action_name(klass)
        {
          SendType => "Send",
          ReceiveType => "Receive",
          SelectType => "Select",
          OfferType => "Offer",
          EndType => "End",
        }.fetch(klass, klass.name)
      end

      def other_side
        side == :left ? :right : :left
      end
    end

    module Connection
      module_function

      def pair(left_type, right_type, queues: nil)
        left = Types.normalize(left_type, :left)
        right = Types.normalize(right_type, :right)
        Types.assert_dual!(left, right)

        left_out, right_out = build_queues(queues)
        left_endpoint = Endpoint.new(
          left,
          inbound: right_out,
          outbound: left_out,
          side: :left,
        )
        right_endpoint = Endpoint.new(
          right,
          inbound: left_out,
          outbound: right_out,
          side: :right,
        )
        [left_endpoint, right_endpoint]
      end

      def build_queues(queues)
        return [MemoryQueue.new, MemoryQueue.new] if queues.nil?

        unless queues.is_a?(Array) && queues.length == 2
          raise ArgumentError, "queues must be an Array of two queue objects"
        end

        queues
      end
    end

    def self.pair(left_type, right_type, queues: nil)
      Connection.pair(left_type, right_type, queues: queues)
    end
  end
end
