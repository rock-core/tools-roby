require 'roby/test/self'

module Roby
    describe OrGenerator do
        subject { OrGenerator.new }
        let(:source0) { EventGenerator.new }
        let(:source1) { EventGenerator.new }

        describe "if set up within the plan itself" do
            before do
                plan.add([source0, source1])
            end
            it "emits as soon as one of its sources is emitted" do
                source0.signals subject
                source1.signals subject

                source0.emit
                assert subject.emitted?
                source1.emit
                assert_equal 1, subject.history.size
            end

            it "only considers events at the point where the source was added" do
                source1.emit
                source0.signals subject
                source1.signals subject

                source0.emit
                assert subject.emitted?
                source1.emit
                assert_equal 1, subject.history.size
            end

            it "becomes unreachable if all its sources are" do
                source0.signals subject
                source1.signals subject
                source0.unreachable!
                assert !subject.unreachable?
                source1.unreachable!
                assert subject.unreachable?
            end

            it "does not become unreachable if a source that has already emitted becomes unreachable" do
                source0.signals subject
                source1.signals subject
                source1.emit
                source1.unreachable!
                assert !subject.unreachable?
                source0.unreachable!
                assert !subject.unreachable?
            end

            it "does not become unreachable for events that have been removed" do
                source0.signals subject
                source1.signals subject
                source1.remove_signal subject
                source1.unreachable!
                assert !subject.unreachable?
            end

            it "becomes unreachable if the removal of an event causes all the events to be unreachable" do
                source0.signals subject
                source1.signals subject
                source1.unreachable!
                source0.remove_signal subject
                assert subject.unreachable?
            end
        end

        describe "if merged into the plan" do
            before do
                source0.signals subject
                source1.signals subject
                plan.add(subject)
            end

            it "emits when any of its sources have emitted" do
                source0.emit
                assert subject.emitted?
                source1.emit
                assert_equal 1, subject.history.size
            end

            it "becomes unreachable if all of its sources are" do
                source0.unreachable!
                assert !subject.unreachable?
                source1.unreachable!
                assert subject.unreachable?
            end

            it "does not become unreachable if a source that has already emitted becomes unreachable" do
                source1.emit
                source1.unreachable!
                assert !subject.unreachable?
                source0.unreachable!
                assert !subject.unreachable?
            end
        end

        describe "new source relations are added within transaction" do
            before do
                source0.signals subject
                plan.add(source1)
                plan.add(subject)
            end

            it "emits when any of its sources have emitted" do
                plan.in_transaction do |t|
                    t[source1].signals t[subject]
                    t.commit_transaction
                end

                source1.emit
                assert subject.emitted?
                source0.emit
                assert_equal 1, subject.history.size
            end

            it "only considers events at the point where the source was added" do
                source1.emit
                plan.in_transaction do |t|
                    t[source1].signals t[subject]
                    t.commit_transaction
                end

                source1.emit
                assert subject.emitted?
                source0.emit
                assert_equal 1, subject.history.size
            end

            it "becomes unreachable if all sources become unreachable" do
                plan.in_transaction do |t|
                    t[source1].signals t[subject]
                    t.commit_transaction
                end
                source0.unreachable!
                assert !subject.unreachable?
                source1.unreachable!
                assert subject.unreachable?
            end

            it "does not become unreachable if a source that has already emitted becomes unreachable" do
                plan.in_transaction do |t|
                    t[source1].signals t[subject]
                    t.commit_transaction
                end
                source0.unreachable!
                source1.emit
                source1.unreachable!
                assert !subject.unreachable?
                assert subject.emitted?
            end
        end

        describe "source relations are removed using a transaction" do
            before do
                source0.signals subject
                source1.signals subject
                plan.add(subject)
            end

            it "does not emit with the removed source" do
                plan.in_transaction do |t|
                    t[source1].remove_signal t[subject]
                    t.commit_transaction
                end
                source1.emit
                assert !subject.emitted?
                source0.emit
                assert subject.emitted?
            end
        end

        describe "new source events are added within transaction" do
            before do
                source0.signals subject
                plan.add(subject)
            end

            it "emits when the added event is emitted" do
                plan.in_transaction do |t|
                    source1.signals t[subject]
                    t.commit_transaction
                end

                source1.emit
                assert subject.emitted?
            end

            it "becomes unreachable only if the new source also become unreachable" do
                plan.in_transaction do |t|
                    source1.signals t[subject]
                    t.commit_transaction
                end
                source0.unreachable!
                assert !subject.unreachable?
                source1.unreachable!
                assert subject.unreachable?
            end
        end

        describe "#empty?" do
            it "returns true if the event has no source" do
                or_event = OrGenerator.new
                assert(or_event.empty?)
            end

            it "returns false if it has a parent" do
                or_event = OrGenerator.new
                or_event << EventGenerator.new(true)
                assert(!or_event.empty?)
            end
        end

        describe "#reset" do
            it "will emit again if one of its sources emits" do
                source0.signals subject
                source1.signals subject
                plan.add(subject)
                source0.emit
                subject.reset
                source1.emit
                assert_equal 2, subject.history.size
            end
        end
    end
end

