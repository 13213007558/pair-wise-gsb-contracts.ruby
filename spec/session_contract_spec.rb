# frozen_string_literal: true

RSpec.describe "Contracts::Session" do
  let(:session) { Contracts::Session }

  describe "endpoint pairs" do
    it "checks duality before creating endpoints" do
      left = session.send(String)
      right = session.send(String)

      expect do
        session.pair(left, right)
      end.to raise_error(session::DualityError) do |error|
        expect(error.side).to eq(:right)
        expect(error.details[:left]).to be_a(session::SendType)
        expect(error.details[:right]).to be_a(session::SendType)
      end
    end

    it "progresses send and receive one explicit step at a time" do
      left, right = session.pair(session.send(String), session.receive(String))

      expect(left.send!("hello")).to eq("hello")
      expect(right.receive!).to eq("hello")

      left.close!
      right.close!
      expect(left).to be_closed
      expect(right).to be_closed
    end

    it "validates message bodies with the existing Contracts validator" do
      left, right = session.pair(session.send(Integer), session.receive(Integer))

      expect do
        left.send!("one")
      end.to raise_error(session::MessageContractError) do |error|
        expect(error.side).to eq(:left)
        expect(error.data[:arg]).to eq("one")
        expect(error.data[:contract]).to eq(Integer)
        expect(left.state).to be_a(session::SendType)
      end

      right.inbound.push(session::Message.new(payload: "two"))
      expect do
        right.receive!
      end.to raise_error(session::MessageContractError) do |error|
        expect(error.side).to eq(:left)
        expect(error.data[:arg]).to eq("two")
      end
    end
  end

  describe "choices" do
    let(:left_type) do
      session.select(
        yes: session.send(Integer, session.end_session),
        no: session.end_session,
      )
    end

    it "matches a selected branch with an offered branch" do
      left, right = session.pair(left_type, session.dual(left_type))

      expect(left.select!(:yes)).to eq(:yes)
      expect(right.offer!(:yes)).to eq(:yes)
      expect(left.send!(42)).to eq(42)
      expect(right.receive!).to eq(42)

      left.close!
      right.close!
      expect(left).to be_closed
    end

    it "reports the right side when a branch name is right but the direction is not" do
      wrong_direction = session.select(yes: session.end_session, no: session.end_session)

      expect do
        session.pair(left_type, wrong_direction)
      end.to raise_error(session::DualityError, /:yes.*wrong direction/) do |error|
        expect(error.side).to eq(:right)
      end
    end

    it "reports the endpoint that calls the wrong branching action" do
      left, right = session.pair(left_type, session.dual(left_type))

      expect do
        right.select!(:yes)
      end.to raise_error(session::ProtocolViolation, /expected Select.*Offer/) do |error|
        expect(error.side).to eq(:right)
      end

      expect do
        left.offer!(:yes)
      end.to raise_error(session::ProtocolViolation, /expected Offer.*Select/) do |error|
        expect(error.side).to eq(:left)
      end
    end

    it "reports the side that sends an unknown branch label" do
      left, right = session.pair(left_type, session.dual(left_type))

      expect do
        left.select!(:maybe)
      end.to raise_error(session::ProtocolViolation, /unknown branch :maybe/) do |error|
        expect(error.side).to eq(:left)
      end

      right.inbound.push(session::BranchSelection.new(label: :maybe))
      expect do
        right.offer!
      end.to raise_error(session::ProtocolViolation, /unknown branch :maybe/) do |error|
        expect(error.side).to eq(:left)
      end
    end
  end

  describe "termination" do
    it "reports the side that closes before End" do
      left, _right = session.pair(session.send(String), session.receive(String))

      expect do
        left.close!
      end.to raise_error(session::ProtocolViolation, /closed before the protocol reached End/) do |error|
        expect(error.side).to eq(:left)
      end
    end

    it "reports operations made after close as the operating side" do
      left, right = session.pair(session.end_session, session.end_session)
      left.close!
      right.close!

      expect do
        left.close!
      end.to raise_error(session::ProtocolViolation, /operated on a closed endpoint/) do |error|
        expect(error.side).to eq(:left)
      end
    end
  end

  describe "recursion" do
    let(:protocol) do
      session.rec(:poll) do |again|
        session.select(
          next: session.receive(Integer, session.send(String, again)),
          stop: session.end_session,
        )
      end
    end

    it "returns to the protocol head with separate endpoint state" do
      left, right = session.pair(protocol, session.dual(protocol))

      2.times do
        expect(left.select!(:next)).to eq(:next)
        expect(right.offer!(:next)).to eq(:next)
        expect(right.send!(7)).to eq(7)
        expect(left.receive!).to eq(7)
        expect(left.send!("ok")).to eq("ok")
        expect(right.receive!).to eq("ok")
      end

      expect(left.select!(:stop)).to eq(:stop)
      expect(right.offer!(:stop)).to eq(:stop)
      left.close!
      right.close!

      expect(left.frames.keys).not_to match_array(right.frames.keys)
    end

    it "returns from a nested recursion to an outer recursion" do
      nested_protocol = session.rec(:outer) do |outer|
        session.select(
          inner: session.rec(:inner) do |inner|
            session.select(
              again: session.receive(Integer, session.send(String, inner)),
              leave: session.send(Symbol, outer),
            )
          end,
          stop: session.end_session,
        )
      end
      left, right = session.pair(nested_protocol, session.dual(nested_protocol))

      left.select!(:inner)
      right.offer!(:inner)
      left.select!(:again)
      right.offer!(:again)
      right.send!(1)
      left.receive!
      left.send!("ok")
      right.receive!
      left.select!(:leave)
      right.offer!(:leave)
      left.send!(:done)
      right.receive!

      left.select!(:inner)
      right.offer!(:inner)
      left.select!(:leave)
      right.offer!(:leave)
      left.send!(:again)
      right.receive!

      left.select!(:stop)
      right.offer!(:stop)
      left.close!
      right.close!

      expect(left).to be_closed
      expect(right).to be_closed
    end

    it "does not mix recursion state between endpoint pairs" do
      _left, _right = session.pair(protocol, session.dual(protocol))
      other_left, other_right = session.pair(protocol, session.dual(protocol))
      foreign = session::RecursionVariable.new(:poll, other_left.type.runtime_id)
      foreign_state = session.send(String, foreign)
      expect do
        other_right.instance_variable_set(:@state, foreign_state)
        other_right.send!("foreign")
      end.to raise_error(session::ProtocolViolation, /from another session/) do |error|
        expect(error.side).to eq(:right)
      end
    end
  end

  describe "in-memory queues" do
    it "uses only explicit steps and raises instead of waiting" do
      _left, right = session.pair(session.send(String), session.receive(String))

      expect do
        right.receive!
      end.to raise_error(session::WouldBlockError) do |error|
        expect(error.side).to eq(:right)
      end
    end

    it "accepts supplied queues" do
      left_out = session::MemoryQueue.new
      right_out = session::MemoryQueue.new
      left, right = session.pair(
        session.send(String),
        session.receive(String),
        queues: [left_out, right_out],
      )

      left.send!("queued")
      expect(left_out).not_to be_empty
      expect(right.receive!).to eq("queued")
    end
  end
end
