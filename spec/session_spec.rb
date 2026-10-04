# frozen_string_literal: true

RSpec.describe Contracts::Session do
  let(:counter_protocol) do
    described_class.contract do
      recurse(:counter) do |again|
        send(Integer, internal(again: again, stop: finish))
      end
    end
  end

  describe "endpoint pair creation" do
    it "accepts a protocol and its dual" do
      pair = described_class.pair(counter_protocol)

      expect(pair.left.state).to be_a(described_class::Recursion)
      expect(pair.right.state).to be_a(described_class::Recursion)
      expect(pair.left.outbox).not_to be(pair.right.outbox)
    end

    it "rejects two protocols with the same communication direction" do
      expect do
        described_class.pair(counter_protocol, counter_protocol)
      end.to raise_error(described_class::TypeError) do |error|
        expect(error.side).to eq(:right)
        expect(error.expected).to eq(described_class::Receive)
        expect(error.actual).to eq(described_class::Send)
      end
    end

    it "rejects correctly named branches on the wrong side of choice" do
      client = described_class.contract do
        internal(add: send(Integer, finish), quit: finish)
      end
      server = described_class.contract do
        internal(add: receive(Integer, finish), quit: finish)
      end

      expect do
        described_class.pair(client, server)
      end.to raise_error(described_class::TypeError, /not dual/) do |error|
        expect(error.side).to eq(:right)
        expect(error.expected).to eq(described_class::ExternalChoice)
        expect(error.actual).to eq(described_class::InternalChoice)
      end
    end

    it "rejects recursion variables that refer to the wrong recursive state" do
      client = described_class.contract do
        recurse(:outer) do |outer|
          send(Integer, internal(
            outer: outer,
            inner: recurse(:inner) do |inner|
              receive(Integer, external(repeat: inner, done: outer))
            end,
          ))
        end
      end

      bad_server = described_class.contract do
        recurse(:outer) do |outer|
          receive(Integer, external(
            outer: outer,
            inner: recurse(:inner) do |inner|
              send(Integer, internal(repeat: outer, done: inner))
            end,
          ))
        end
      end

      expect do
        described_class.pair(client, bad_server)
      end.to raise_error(described_class::TypeError, /recursion states were mixed/) do |error|
        expect(error.side).to eq(:right)
      end
    end
  end

  describe "single-step protocol execution" do
    it "advances messages, external choices, recursion, and completion" do
      pair = described_class.pair(counter_protocol)

      expect do
        pair.left.send(1)
      end.to change { pair.left.outbox.empty? }.from(true).to(false)

      expect(pair.right.receive).to eq(1)
      expect(pair.left.select(:again)).to eq(:again)
      expect(pair.right.offer).to eq(:again)

      expect(pair.left.send(2)).to eq(2)
      expect(pair.right.receive).to eq(2)
      expect(pair.left.select(:stop)).to eq(:stop)
      expect(pair.right.offer).to eq(:stop)

      expect(pair.left.close).to eq(true)
      expect(pair.right.close).to eq(true)
    end

    it "does not advance when the in-memory queue is empty" do
      pair = described_class.pair(counter_protocol)

      expect { pair.right.receive }.to raise_error(described_class::EmptyQueue)
      expect(pair.right.state).to be_a(described_class::Recursion)
      expect(pair.right.inbox.empty?).to eq(true)
    end

    it "reports the endpoint that sends a body failing its existing Contract" do
      pair = described_class.pair(counter_protocol)

      expect do
        pair.left.send("not an integer")
      end.to raise_error(described_class::MessageError) do |error|
        expect(error.side).to eq(:left)
        expect(error.expected).to eq(Integer)
        expect(error.actual).to eq("not an integer")
      end

      expect(pair.left.outbox.empty?).to eq(true)
      expect(pair.left.state).to be_a(described_class::Recursion)
    end

    it "reports the local endpoint that calls receive where it must send" do
      pair = described_class.pair(counter_protocol)

      expect do
        pair.left.receive
      end.to raise_error(described_class::ProtocolViolation, /cannot receive/) do |error|
        expect(error.side).to eq(:left)
        expect(error.expected).to eq("receive")
        expect(error.actual).to eq("send")
      end
    end

    it "reports the local endpoint that offers a branch where it must select" do
      pair = described_class.pair(counter_protocol)
      pair.left.send(1)
      pair.right.receive

      expect do
        pair.left.offer
      end.to raise_error(described_class::ProtocolViolation, /cannot offer/) do |error|
        expect(error.side).to eq(:left)
        expect(error.expected).to eq("offer")
        expect(error.actual).to eq("select")
      end
    end

    it "reports the endpoint that selects a branch name not in its own contract" do
      protocol = described_class.contract { internal(add: finish, quit: finish) }
      pair = described_class.pair(protocol)

      expect do
        pair.left.select(:remove)
      end.to raise_error(described_class::ProtocolViolation) do |error|
        expect(error.side).to eq(:left)
        expect(error.expected).to eq([:add, :quit])
        expect(error.actual).to eq(:remove)
      end
    end

    it "reports the endpoint that closes before End" do
      pair = described_class.pair(counter_protocol)

      expect do
        pair.left.close
      end.to raise_error(described_class::ProtocolViolation, /before the protocol reached End/) do |error|
        expect(error.side).to eq(:left)
        expect(error.actual).to be_a(described_class::Send)
      end

      expect(pair.left.closed?).to eq(false)
    end

    it "does not treat a completed peer close as an early close" do
      pair = described_class.pair(counter_protocol)

      pair.left.send(1)
      pair.right.receive
      pair.left.select(:stop)
      pair.right.offer
      pair.left.close

      expect(pair.right.close).to eq(true)
    end

    it "reports the peer when it closes a queue while the other endpoint still expects a message" do
      pair = described_class.pair(counter_protocol)
      pair.left.outbox.close

      expect do
        pair.right.receive
      end.to raise_error(described_class::ProtocolViolation, /peer closed before the protocol reached End/) do |error|
        expect(error.side).to eq(:left)
      end
    end

    it "validates structured message bodies with the existing Contracts library" do
      protocol = described_class.contract do
        send({ amount: Contracts::Builtin::Nat, note: String }, finish)
      end
      pair = described_class.pair(protocol)

      pair.left.send(amount: 1, note: "ok")
      expect(pair.right.receive).to eq(amount: 1, note: "ok")

      pair.left.close
      pair.right.close
    end
  end
end
