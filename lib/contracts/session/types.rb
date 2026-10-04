# frozen_string_literal: true

require "set"

module Contracts
  module Session
    class EndType

      def inspect
        "End"
      end
      alias_method :to_s, :inspect
    end

    End = EndType.new.freeze

    class SendType
      attr_reader :contract, :continuation

      def initialize(contract, continuation)
        @contract = contract
        @continuation = continuation
      end

      def inspect
        "Send(#{inspect_contract(contract)}, #{continuation.inspect})"
      end
      alias_method :to_s, :inspect

      def ==(other)
        other.is_a?(self.class) &&
          contracts_equal?(contract, other.contract) &&
          continuation == other.continuation
      end
      alias_method :eql?, :==

      def hash
        [self.class, contract_id(contract), continuation].hash
      end

      private

      def inspect_contract(contract)
        contract.respond_to?(:inspect) ? contract.inspect : contract.to_s
      end

      def contracts_equal?(left, right)
        return true if left.equal?(right)

        left == right
      end

      def contract_id(contract)
        contract.respond_to?(:object_id) ? contract.object_id : contract
      end
    end

    class ReceiveType < SendType
      def inspect
        "Receive(#{inspect_contract(contract)}, #{continuation.inspect})"
      end
    end

    class Branch
      attr_reader :label, :continuation

      def initialize(label, continuation)
        @label = label
        @continuation = continuation
      end

      def inspect
        "#{label.inspect} => #{continuation.inspect}"
      end
      alias_method :to_s, :inspect

      def ==(other)
        other.is_a?(self.class) &&
          label == other.label &&
          continuation == other.continuation
      end
      alias_method :eql?, :==

      def hash
        [label, continuation].hash
      end
    end

    class ChoiceType
      attr_reader :branches

      def initialize(branches)
        @branches = normalize_initial_branches(branches)
      end

      def labels
        branches.map(&:label)
      end

      def [](label)
        branch = branches.find { |candidate| candidate.label == label }
        branch&.continuation
      end

      def inspect
        "#{choice_name}(#{branches.map(&:inspect).join(", ")})"
      end
      alias_method :to_s, :inspect

      def ==(other)
        other.is_a?(self.class) && branches == other.branches
      end
      alias_method :eql?, :==

      def hash
        [self.class, branches].hash
      end

      private

      def normalize_initial_branches(branches)
        if branches.is_a?(Hash) && !branches.empty?
          branches.map { |label, continuation| Branch.new(label.to_sym, continuation) }
        else
          branches
        end
      end

      def choice_name
        raise NotImplementedError
      end
    end

    class SelectType < ChoiceType
      private

      def choice_name
        "Select"
      end
    end

    class OfferType < ChoiceType
      private

      def choice_name
        "Offer"
      end
    end

    class RecursionVariable
      attr_reader :name, :target

      def initialize(name, target = nil)
        @name = name.to_sym
        @target = target
      end

      def inspect
        name.inspect
      end
      alias_method :to_s, :inspect

      def ==(other)
        other.is_a?(self.class) && identity == other.identity
      end
      alias_method :eql?, :==

      def hash
        [self.class, identity].hash
      end

      def identity
        target || name
      end
    end

    class RecursionType
      attr_reader :name, :body

      def initialize(name, body, runtime_id = nil)
        @name = name.to_sym
        @body = body
        @runtime_id = runtime_id
        @stable = false
      end

      def runtime_id
        @runtime_id ||= object_id
      end

      def stable!
        @stable = true
        self
      end

      def stable?
        @stable == true
      end

      def body=(body)
        @body = body
      end

      def inspect
        "Rec(#{name.inspect}, #{body.inspect})"
      end
      alias_method :to_s, :inspect

      def ==(other)
        other.is_a?(self.class) && name == other.name && body == other.body
      end
      alias_method :eql?, :==

      def hash
        [self.class, name, body].hash
      end
    end

    module DSL
      extend self

      def end_session
        End
      end

      def send(contract, continuation = End)
        SendType.new(contract, continuation)
      end
      alias_method :send_message, :send

      def receive(contract, continuation = End)
        ReceiveType.new(contract, continuation)
      end

      def select(branches)
        SelectType.new(branches)
      end

      def offer(branches)
        OfferType.new(branches)
      end

      def rec(name = nil, &block)
        raise InvalidSessionType, "a recursion needs a block" unless block

        recursion_name = (name || "rec_#{block.object_id}").to_sym
        recursion = RecursionType.new(recursion_name, End)
        variable = RecursionVariable.new(recursion_name, recursion.runtime_id)
        recursion.body = block.call(variable)
        recursion
      end
      alias_method :mu, :rec
      alias_method :recursion, :rec
    end

    module Types
      module_function

      def normalize(type, side = nil, variables = nil)
        variables ||= {}
        case type
        when nil, End
          End
        when ReceiveType
          ReceiveType.new(type.contract, normalize(type.continuation, side, variables))
        when SendType
          SendType.new(type.contract, normalize(type.continuation, side, variables))
        when SelectType
          SelectType.new(normalize_choice(type, side, variables))
        when OfferType
          OfferType.new(normalize_choice(type, side, variables))
        when RecursionType
          normalize_recursion(type, side, variables)
        when RecursionVariable
          normalize_variable(type, side, variables)
        else
          raise InvalidSessionType.new(
            "#{side || "session"} endpoint has an invalid session type: #{type.inspect}",
            side: side,
          )
        end
      end

      def dual(type)
        type = normalize(type)
        case type
        when End
          End
        when ReceiveType
          SendType.new(type.contract, dual(type.continuation))
        when SendType
          ReceiveType.new(type.contract, dual(type.continuation))
        when SelectType
          OfferType.new(type.branches.map { |branch| dual_branch(branch) })
        when OfferType
          SelectType.new(type.branches.map { |branch| dual_branch(branch) })
        when RecursionType
          recursion = RecursionType.new(type.name, dual(type.body), type.runtime_id)
          recursion.stable!
          recursion
        when RecursionVariable
          type
        end
      end

      def assert_dual!(left, right)
        unless dual?(left, right)
          raise DualityError.new(
            duality_message(left, right),
            side: :right,
            details: { left: left, right: right },
          )
        end
      end

      def dual?(left, right, bindings = nil)
        bindings ||= { active: [] }
        return bound_variable_pair?(left, right, bindings) if both_variables?(left, right)

        case left
        when EndType
          right.is_a?(EndType)
        when ReceiveType
          right.is_a?(SendType) &&
            contracts_equal?(left.contract, right.contract) &&
            dual?(left.continuation, right.continuation, bindings)
        when SendType
          right.is_a?(ReceiveType) &&
            contracts_equal?(left.contract, right.contract) &&
            dual?(left.continuation, right.continuation, bindings)
        when ChoiceType
          dual_choice?(left, right, bindings)
        when RecursionType
          dual_recursion?(left, right, bindings)
        when RecursionVariable
          dual_variable?(left, right, bindings)
        else
          false
        end
      end

      def normalize_choice(type, side, variables)
        type.branches.map do |branch|
          Branch.new(branch.label, normalize(branch.continuation, side, variables))
        end
      end

      def normalize_recursion(type, side, variables)
        return stable_recursion(type, side, variables) if type.stable?

        recursion_ids = collect_raw_recursion_ids(type, {})
        next_variables = variables.merge(recursion_ids)
        recursion = RecursionType.new(type.name, End, recursion_ids[type.runtime_id]).stable!
        recursion.body = normalize(type.body, side, next_variables)
        ensure_productive!(recursion, side)
        recursion
      end

      def collect_raw_recursion_ids(type, ids)
        next_ids = ids.merge(type.runtime_id => next_recursion_id)

        case type.body
        when SendType, ReceiveType
          collect_recursion_ids_from(type.body, next_ids)
        when ChoiceType
          type.body.branches.reduce(next_ids) do |current_ids, branch|
            collect_recursion_ids_from(branch.continuation, current_ids)
          end
        when RecursionType
          collect_raw_recursion_ids(type.body, next_ids)
        else
          next_ids
        end
      end

      def collect_recursion_ids_from(type, ids)
        case type
        when SendType, ReceiveType
          collect_recursion_ids_from(type.continuation, ids)
        when ChoiceType
          type.branches.reduce(ids) do |current_ids, branch|
            collect_recursion_ids_from(branch.continuation, current_ids)
          end
        when RecursionType
          collect_raw_recursion_ids(type, ids)
        else
          ids
        end
      end

      def next_recursion_id
        @next_recursion_id ||= 100
        @next_recursion_id += 20
      end

      def stable_recursion(type, side, variables)
        recursion = RecursionType.new(type.name, End, type.runtime_id).stable!
        recursion.body = normalize(type.body, side, variables)
        recursion
      end

      def normalize_variable(type, side, variables)
        return RecursionVariable.new(type.name, variables[type.target]) if type.target && variables.key?(type.target)
        return type if type.target
        return RecursionVariable.new(type.name, variables[type.name]) if variables.key?(type.name)

        raise InvalidSessionType.new(
          "#{side || "session"} endpoint refers to unknown recursion #{type.name.inspect}",
          side: side,
        )
      end

      def ensure_productive!(recursion, side)
        return if productive?(recursion.body, recursion.name, Set.new)

        raise InvalidSessionType.new(
          "#{side || "session"} endpoint recursion #{recursion.name.inspect} has no action before looping",
          side: side,
        )
      end

      def productive?(type, recursion_name, seen)
        case type
        when SendType, ReceiveType
          true
        when ChoiceType
          type.branches.any? do |branch|
            productive?(branch.continuation, recursion_name, seen)
          end
        when RecursionType
          return false if seen.include?(type.name)

          productive?(type.body, recursion_name, Set.new(seen).add(type.name))
        when RecursionVariable
          type.name != recursion_name
        else
          false
        end
      end

      def dual_branch(branch)
        Branch.new(branch.label, dual(branch.continuation))
      end

      def dual_choice?(left, right, bindings)
        return false unless right.is_a?(ChoiceType)
        return false unless left.labels.sort == right.labels.sort
        return false if left.is_a?(right.class)

        left.branches.all? do |branch|
          dual?(branch.continuation, right[branch.label], bindings)
        end
      end

      def dual_recursion?(left, right, bindings)
        if right.is_a?(RecursionVariable)
          return matches_recursion_variable?(left, right, bindings)
        end
        return false unless right.is_a?(RecursionType)

        bindings[:active].push([left.runtime_id, right.runtime_id])
        result = dual?(left.body, right.body, bindings)
        bindings[:active].pop
        result
      end

      def dual_variable?(left, right, bindings)
        return false unless right.is_a?(RecursionVariable)

        bindings[:active].any? do |active_left, active_right|
          [active_left, active_right].sort == [left.identity, right.identity].sort
        end
      end

      def bound_variable_pair?(left, right, bindings)
        return false unless both_variables?(left, right)

        dual_variable?(left, right, bindings)
      end

      def both_variables?(left, right)
        left.is_a?(RecursionVariable) && right.is_a?(RecursionVariable)
      end

      def matches_recursion_variable?(left, right, bindings)
        bindings[:active].any? do |active_left, active_right|
          (active_left == left.runtime_id && active_right == right.identity) ||
            (active_right == left.runtime_id && active_left == right.identity)
        end
      end

      def contracts_equal?(left, right)
        left.equal?(right) || left == right
      end

      def duality_message(left, right)
        expected = dual(left)
        common_labels = common_branch_labels(left, right)
        direction_note = direction_note(left, right, common_labels)
        label_note = label_note(left, right, common_labels)

        "right endpoint violates session contract: expected #{expected.inspect}, got #{right.inspect}" \
          "#{direction_note}#{label_note}"
      end

      def common_branch_labels(left, right)
        return [] unless left.is_a?(ChoiceType) && right.is_a?(ChoiceType)

        left.labels & right.labels
      end

      def direction_note(left, right, labels)
        return "" unless wrong_branch_direction?(left, right)

        label_text = labels.empty? ? "" : " #{labels.map(&:inspect).join(", ")}"
        "; branch#{label_text} has the correct name but the wrong direction: " \
          "left uses #{choice_name(left)}, right uses #{choice_name(right)}"
      end

      def wrong_branch_direction?(left, right)
        left.is_a?(ChoiceType) && right.is_a?(left.class)
      end

      def label_note(left, right, common_labels)
        return "" unless left.is_a?(ChoiceType) && right.is_a?(ChoiceType)
        return "" if common_labels == left.labels && common_labels == right.labels

        "; left offers #{left.labels.inspect}, right offers #{right.labels.inspect}"
      end

      def choice_name(type)
        type.is_a?(SelectType) ? "Select" : "Offer"
      end
    end

    extend DSL

    def self.dual(type)
      Types.dual(type)
    end
  end
end
