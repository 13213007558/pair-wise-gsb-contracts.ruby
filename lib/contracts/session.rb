# frozen_string_literal: true

module Contracts
  module Session
    class Error < StandardError; end

    class EmptyQueue < Error; end

    class ClosedQueue < Error; end

    class ContractViolation < Error
      attr_reader :side, :expected, :actual, :contract

      def initialize(message, side:, expected: nil, actual: nil, contract: nil)
        super(message)
        @side = side
        @expected = expected
        @actual = actual
        @contract = contract
      end
    end

    class TypeError < ContractViolation; end

    class MessageError < ContractViolation; end

    class ProtocolViolation < ContractViolation; end

    class SessionType
    end

    class EndType < SessionType
      def inspect
        "End"
      end
    end

    End = EndType.new.freeze

    class Message < SessionType
      attr_reader :payload_contract, :continuation

      def initialize(payload_contract, continuation = End)
        @payload_contract = payload_contract
        @continuation = continuation
        freeze
      end
    end

    class Send < Message; end

    class Receive < Message; end

    class Choice < SessionType
      attr_reader :branches

      def initialize(branches)
        unless branches.is_a?(Hash) && !branches.empty?
          fail ArgumentError, "branches must be a non-empty Hash"
        end

        @branches = branches.dup.freeze
        freeze
      end

      def branch_names
        branches.keys
      end
    end

    class InternalChoice < Choice; end

    class ExternalChoice < Choice; end

    class Recursion < SessionType
      attr_reader :name
      attr_accessor :body

      def initialize(name, body = nil)
        @name = name
        @body = body
      end
    end

    class Variable < SessionType
      attr_reader :name
      attr_accessor :recursion

      def initialize(name, recursion = nil)
        @name = name
        @recursion = recursion
        freeze
      end
    end

    class MemoryQueue
      def initialize
        @items = []
        @closed = false
      end

      def push(item)
        fail ClosedQueue if closed?

        @items.push(item)
      end

      def pop
        fail EmptyQueue if @items.empty?

        item = @items.shift
        item == :close ? [item] : item
      end

      def close
        @items.push(:close) unless @items.include?(:close)
        @closed = true
      end

      def closed?
        @closed
      end

      def empty?
        @items.empty?
      end
    end

    Pair = Struct.new(:left, :right) do
      def endpoints
        [left, right]
      end
    end

    class Endpoint
      attr_reader :side, :state, :outbox, :inbox

      def initialize(side, state, outbox, inbox)
        @side = side
        @state = state
        @outbox = outbox
        @inbox = inbox
      end

      def closed?
        outbox.closed?
      end

      def send(payload)
        type = unfold
        assert_action!(type, Session::Send, :send)
        validate_payload!(type, payload)
        outbox.push([:message, payload])
        @state = type.continuation
        payload
      end

      def receive
        type = unfold
        assert_action!(type, Session::Receive, :receive)
        kind, payload = pop_from_peer!
        unless kind == :message
          fail_protocol!(:message, kind, "peer sent a branch where a message was expected", peer_side)
        end
        validate_peer_payload!(type, payload)
        @state = type.continuation
        payload
      end

      def select(branch_name)
        type = unfold
        assert_action!(type, Session::InternalChoice, :select)
        assert_branch_name!(type, branch_name)
        outbox.push([:branch, branch_name])
        @state = type.branches.fetch(branch_name)
        branch_name
      end

      def offer
        type = unfold
        assert_action!(type, Session::ExternalChoice, :offer)
        kind, branch_name = pop_from_peer!
        unless kind == :branch
          fail_protocol!(:branch, kind, "peer sent a message where a branch was expected", peer_side)
        end
        unless type.branches.key?(branch_name)
          fail_protocol!(type.branch_names, branch_name, "peer selected an unknown branch", peer_side)
        end
        @state = type.branches.fetch(branch_name)
        branch_name
      end

      def close
        type = unfold
        unless type.is_a?(Session::EndType)
          fail_protocol!(Session::EndType, type, "endpoint closed before the protocol reached End", side)
        end

        outbox.close
        true
      end

      private

      def unfold
        type = state
        while type.is_a?(Session::Recursion) || type.is_a?(Session::Variable)
          type = type.is_a?(Session::Recursion) ? type.body : type.recursion.body
        end
        type
      end

      def assert_action!(type, expected, action)
        return if type.is_a?(expected)

        actual = type_description(type)
        expected_description = type_description(expected)
        fail ProtocolViolation.new(
          "#{side} endpoint cannot #{action} in state #{actual}",
          side: side,
          expected: expected_description,
          actual: actual,
          contract: type,
        )
      end

      def assert_branch_name!(type, branch_name)
        return if type.branches.key?(branch_name)

        fail_protocol!(type.branch_names, branch_name, "endpoint selected an unknown branch", side)
      end

      def validate_payload!(type, payload)
        return if Contract.valid?(payload, type.payload_contract)

        fail MessageError.new(
          "#{side} endpoint sent a message that violates its payload contract",
          side: side,
          expected: type.payload_contract,
          actual: payload,
          contract: type,
        )
      end

      def validate_peer_payload!(type, payload)
        return if Contract.valid?(payload, type.payload_contract)

        fail MessageError.new(
          "#{peer_side} endpoint sent a message that violates #{side} endpoint payload contract",
          side: peer_side,
          expected: type.payload_contract,
          actual: payload,
          contract: type,
        )
      end

      def pop_from_peer!
        item = inbox.pop
        if item == [:close]
          fail_protocol!(:active, :close, "peer closed before the protocol reached End", peer_side)
        end
        item
      end

      def fail_protocol!(expected, actual, message, violating_side)
        fail ProtocolViolation.new(
          message,
          side: violating_side,
          expected: expected,
          actual: actual,
          contract: state,
        )
      end

      def peer_side
        side == :left ? :right : :left
      end

      def type_description(type)
        action_names.fetch(type) do
          action_names.fetch(type.class) { wordify(type.class.name.split("::").last) }
        end
      end

      def action_names
        {
          Session::Send => "send",
          Session::Receive => "receive",
          Session::InternalChoice => "select",
          Session::ExternalChoice => "offer",
          Session::EndType => "end",
        }
      end

      def wordify(name)
        name.gsub(/([a-z\d])([A-Z])/, "\\1_\\2").downcase
      end
    end

    class Builder
      def build(&block)
        type = instance_exec(&block)
        TypeValidator.validate!(type)
        type
      end

      def send(payload_contract, continuation = End)
        Session::Send.new(payload_contract, continuation)
      end

      def receive(payload_contract, continuation = End)
        Session::Receive.new(payload_contract, continuation)
      end

      def internal(branches)
        Session::InternalChoice.new(branches)
      end

      def external(branches)
        Session::ExternalChoice.new(branches)
      end

      def recurse(name, &block)
        recursion = Session::Recursion.new(name)
        variable = Session::Variable.new(name, recursion)
        recursion.body = block.call(variable)
        recursion.freeze
        recursion
      end

      def finish
        Session::End
      end
    end

    class TypeValidator
      def self.validate!(type, side: nil)
        new(side).validate(type, false)
      end

      def initialize(side)
        @side = side
        @active = {}
        @bound = {}
      end

      def validate(type, guarded)
        case type
        when Session::EndType
          nil
        when Session::Message
          validate(type.continuation, true)
        when Session::Choice
          validate_choice!(type)
        when Session::Recursion
          validate_recursion!(type, guarded)
        when Session::Variable
          validate_variable!(type, guarded)
        else
          reject!("expected a session type", expected: Session::SessionType, actual: type, contract: type)
        end
      end

      private

      def validate_choice!(type)
        type.branches.each_pair do |name, continuation|
          unless name.is_a?(Symbol) && !name.empty?
            reject!("branch names must be non-empty Symbols", expected: Symbol, actual: name, contract: type)
          end
          validate(continuation, true)
        end
      end

      def validate_recursion!(type, guarded)
        return if guarded && @active.key?(type.object_id)
        if @active.key?(type.object_id)
          reject!("recursion #{type.name.inspect} must be guarded by a message or choice", contract: type)
        end

        if type.body.nil?
          reject!("recursion #{type.name.inspect} has no body", contract: type)
        end

        @active[type.object_id] = true
        @bound[type.object_id] = true
        begin
          validate(type.body, false)
        ensure
          @active.delete(type.object_id)
        end
      end

      def validate_variable!(type, guarded)
        recursion = type.recursion
        if recursion.nil? || !@bound.key?(recursion.object_id) || recursion.name != type.name
          reject!("unbound recursion variable #{type.name.inspect}", contract: type)
        end
        return if guarded
        return unless @active.key?(recursion.object_id)

        reject!("recursion #{type.name.inspect} must be guarded by a message or choice", contract: type)
      end

      def reject!(message, expected: nil, actual: nil, contract: nil)
        fail TypeError.new(
          message,
          side: @side,
          expected: expected,
          actual: actual,
          contract: contract,
        )
      end
    end

    class Duality
      MESSAGE_DUALS = {
        Session::Send => Session::Receive,
        Session::Receive => Session::Send,
      }.freeze

      CHOICE_DUALS = {
        Session::InternalChoice => Session::ExternalChoice,
        Session::ExternalChoice => Session::InternalChoice,
      }.freeze

      def self.compatible!(left, right)
        new.compatible!(left, right)
      end

      def initialize
        @seen = {}
      end

      def compatible!(left, right)
        if (left.is_a?(Session::Send) && right.is_a?(Session::Receive)) ||
           (left.is_a?(Session::Receive) && right.is_a?(Session::Send))
          compatible_message!(left, right)
        elsif (left.is_a?(Session::InternalChoice) && right.is_a?(Session::ExternalChoice)) ||
              (left.is_a?(Session::ExternalChoice) && right.is_a?(Session::InternalChoice))
          compatible_choice!(left, right)
        elsif left.is_a?(Session::EndType) && right.is_a?(Session::EndType)
          nil
        elsif left.is_a?(Session::Recursion) && right.is_a?(Session::Recursion)
          compatible_recursion!(left, right)
        elsif left.is_a?(Session::Variable) && right.is_a?(Session::Variable)
          compatible_variable!(left, right)
        else
          reject!(right, expected_dual_of(left), actual: right.class)
        end
      end

      private

      def compatible_message!(left, right)
        unless left.payload_contract == right.payload_contract
          reject!(
            right,
            left.payload_contract,
            actual: right.payload_contract,
            message: "payload contracts do not match",
          )
        end
        compatible!(left.continuation, right.continuation)
      end

      def compatible_choice!(left, right)
        unless left.branch_names.sort == right.branch_names.sort
          reject!(
            right,
            left.branch_names.sort,
            actual: right.branch_names.sort,
            message: "branch names do not match",
          )
        end

        left.branches.each_pair do |name, continuation|
          compatible!(continuation, right.branches.fetch(name))
        end
      end

      def compatible_recursion!(left, right)
        existing = @seen[left.object_id]
        if existing
          return if existing == right.object_id

          reject!(right, right, actual: right, message: "recursion states were mixed")
        end

        @seen[left.object_id] = right.object_id
        compatible!(left.body, right.body)
      end

      def compatible_variable!(left, right)
        expected_recursion_id = @seen[left.recursion.object_id]
        if expected_recursion_id.nil?
          reject!(right, right, actual: right, message: "unbound recursion variable")
        end
        return if right.recursion.object_id == expected_recursion_id

        reject!(right, right, actual: right, message: "recursion states were mixed")
      end

      def expected_dual_of(type)
        MESSAGE_DUALS.fetch(type.class) do
          CHOICE_DUALS.fetch(type.class) { Session::EndType }
        end
      rescue KeyError
        Session::EndType
      end

      def reject!(contract, expected, actual:, message: nil)
        message ||= "right endpoint type is not dual to left endpoint type"
        fail TypeError.new(
          message,
          side: :right,
          expected: expected,
          actual: actual,
          contract: contract,
        )
      end
    end

    class << self
      def contract(&block)
        Builder.new.build(&block)
      end

      def pair(left_type, right_type = nil)
        TypeValidator.validate!(left_type, side: :left)
        right_type ||= dual(left_type)
        TypeValidator.validate!(right_type, side: :right)
        Duality.compatible!(left_type, right_type)

        left_outbox = MemoryQueue.new
        right_outbox = MemoryQueue.new
        left = Endpoint.new(:left, left_type, left_outbox, right_outbox)
        right = Endpoint.new(:right, right_type, right_outbox, left_outbox)
        Pair.new(left, right)
      end

      def dual(type)
        TypeValidator.validate!(type)
        dual_type(type, {})
      end

      private

      def dual_type(type, recursion_bindings)
        case type
        when Session::Send
          Session::Receive.new(type.payload_contract, dual_type(type.continuation, recursion_bindings))
        when Session::Receive
          Session::Send.new(type.payload_contract, dual_type(type.continuation, recursion_bindings))
        when Session::InternalChoice
          Session::ExternalChoice.new(dual_branches(type.branches, recursion_bindings))
        when Session::ExternalChoice
          Session::InternalChoice.new(dual_branches(type.branches, recursion_bindings))
        when Session::EndType
          Session::End
        when Session::Recursion
          dual_recursion(type, recursion_bindings)
        when Session::Variable
          Session::Variable.new(type.name, recursion_bindings.fetch(type.recursion.object_id))
        end
      end

      def dual_branches(branches, recursion_bindings)
        branches.transform_values do |continuation|
          dual_type(continuation, recursion_bindings)
        end
      end

      def dual_recursion(type, recursion_bindings)
        dual_recursion = Session::Recursion.new(type.name)
        recursion_bindings[type.object_id] = dual_recursion
        dual_recursion.body = dual_type(type.body, recursion_bindings)
        dual_recursion.freeze
        dual_recursion
      end
    end
  end
end
