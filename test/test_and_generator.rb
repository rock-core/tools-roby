require 'roby/test/self'

module Roby
    describe AndGenerator do
        subject { AndGenerator.new }
        let(:source0) { EventGenerator.new }
        let(:source1) { EventGenerator.new }

        describe "if set up within the plan itself" do
            before do
                plan.add([source0, source1])
            end
            it "emits when all its sources have emitted" do
                source0.signals subject
                source1.signals subject

                expect_execution { source0.emit }.
                    to { not_emit subject }
                expect_execution { source1.emit }.
                    to { emit subject }
            end

            it "only considers events at the point where the source was added" do
                execute { source1.emit }
                source0.signals subject
                source1.signals subject

                expect_execution { source0.emit }.
                    to { not_emit subject }
                expect_execution { source1.emit }.
                    to { emit subject}
            end

            it "becomes unreachable if any of its sources are" do
                source0.signals subject
                source1.signals subject
                expect_execution { source0.unreachable! }.
                    to { become_unreachable subject }
            end

            it "does not become unreachable if a source that has already emitted becomes unreachable" do
                source0.signals subject
                source1.signals subject
                execute { source1.emit }
                expect_execution { source1.unreachable! }.
                    to { not_become_unreachable subject }
                expect_execution { source0.unreachable! }.
                    to { become_unreachable subject }
            end

            it "does not wait for events that have been removed" do
                source0.signals subject
                source1.signals subject
                source1.remove_signal subject
                expect_execution { source0.emit }.
                    to { emit subject }
            end

            it "emits if the removal of an event causes the AND condition to be met" do
                source0.signals subject
                source1.signals subject
                execute { source0.emit }
                expect_execution { source1.remove_signal subject }.
                    to { emit subject }
            end
        end

        describe "if merged into the plan" do
            it "emits when all its sources have emitted" do
                source0.signals subject
                source1.signals subject
                plan.add(subject)

                expect_execution { source0.emit }.
                    to { not_emit subject }
                expect_execution { source1.emit }.
                    to { emit subject }
            end

            it "becomes unreachable if any of its sources are" do
                source0.signals subject
                source1.signals subject
                plan.add(subject)
                expect_execution { source0.unreachable! }.
                    to { become_unreachable subject }
            end

            it "does not become unreachable if a source that has already emitted becomes unreachable" do
                source0.signals subject
                source1.signals subject
                plan.add(subject)
                execute { source0.emit }
                expect_execution { source0.unreachable! }.
                    to { not_become_unreachable subject }
                expect_execution { source1.emit }.
                    to { emit subject }
            end
        end

        describe "new source relations are added within transaction" do
            before do
                source0.signals subject
                plan.add(source1)
                plan.add(subject)
            end

            it "emits when all its sources have emitted" do
                plan.in_transaction do |t|
                    t[source1].signals t[subject]
                    t.commit_transaction
                end

                expect_execution { source0.emit }.
                    to { not_emit subject }
                expect_execution { source1.emit }.
                    to { emit subject}
            end

            it "only considers events at the point where the source was added" do
                execute { source1.emit }
                plan.in_transaction do |t|
                    t[source1].signals t[subject]
                    t.commit_transaction
                end

                expect_execution { source0.emit }.
                    to { not_emit subject }
                expect_execution { source1.emit }.
                    to { emit subject}
            end

            it "becomes unreachable if a source that has not yet emitted becomes unreachable" do
                plan.in_transaction do |t|
                    t[source1].signals t[subject]
                    t.commit_transaction
                end
                expect_execution { source1.unreachable! }.
                    to { become_unreachable subject }
            end

            it "does not become unreachable if a source that has already emitted becomes unreachable" do
                plan.in_transaction do |t|
                    t[source1].signals t[subject]
                    t.commit_transaction
                end
                execute { source1.emit }
                expect_execution { source1.unreachable! }.
                    to { not_become_unreachable subject }
                expect_execution { source0.emit }.
                    to { emit subject }
            end
        end

        describe "source relations are removed using a transaction" do
            before do
                source0.signals subject
                source1.signals subject
                plan.add(subject)
            end

            it "does not wait for events that have been removed" do
                plan.in_transaction do |t|
                    t[source1].remove_signal t[subject]
                    t.commit_transaction
                end
                expect_execution { source0.emit }.
                    to { emit subject }
            end

            it "does not become unreachable for events that have been removed" do
                plan.in_transaction do |t|
                    t[source1].remove_signal t[subject]
                    t.commit_transaction
                end
                expect_execution { source1.unreachable! }.
                    to { not_become_unreachable subject }
            end

            it "emits if the removal of an event causes the AND condition to be met" do
                execute { source0.emit }
                expect_execution do
                    plan.in_transaction do |t|
                        t[source1].remove_signal t[subject]
                        t.commit_transaction
                    end
                end.to { emit subject }
            end
        end

        describe "new source events are added within transaction" do
            before do
                source0.signals subject
                plan.add(subject)
            end

            it "emits when all its sources have emitted" do
                plan.in_transaction do |t|
                    source1.signals t[subject]
                    t.commit_transaction
                end

                expect_execution { source0.emit }.
                    to { not_emit subject }
                expect_execution { source1.emit }.
                    to { emit subject}
            end

            it "becomes unreachable if any of its sources are" do
                plan.in_transaction do |t|
                    source1.signals t[subject]
                    t.commit_transaction
                end
                expect_execution { source1.unreachable! }.
                    to { become_unreachable subject }
            end
            it "does not become unreachable if a source that has already emitted becomes unreachable" do
                plan.in_transaction do |t|
                    source1.signals t[subject]
                    t.commit_transaction
                end
                execute { source1.emit }
                expect_execution { source1.unreachable! }.
                    to { not_become_unreachable subject }
                expect_execution { source0.emit }.
                    to { emit subject }
            end
        end

        describe "#empty?" do
            it "returns true if the event has no source" do
                and_event = AndGenerator.new
                assert(and_event.empty?)
            end

            it "returns false if it has a parent" do
                and_event = AndGenerator.new
                and_event << EventGenerator.new(true)
                assert(!and_event.empty?)
            end
        end

        describe "#reset" do
            it "forgets about already emitted events" do
                source0.signals subject
                source1.signals subject
                plan.add(subject)
                execute { source0.emit }
                subject.reset
                expect_execution { source1.emit }.
                    to { not_emit subject }
                expect_execution { source0.emit }.
                    to { emit subject }
            end
        end
    end
end

