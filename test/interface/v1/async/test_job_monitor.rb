# frozen_string_literal: true

require "roby/test/self"
require "roby/interface/v1/async"
module Roby
    module Interface
        module V1
            module Async
                describe JobMonitor do
                    attr_reader :job_monitor

                    before do
                        @job_monitor = JobMonitor.new(flexmock, 1)
                    end

                    def states
                        Roby::Interface
                    end

                    describe "state management" do
                        it "has none of the predicates set when initialized in REACHABLE state" do
                            refute job_monitor.planning_finished?
                            refute job_monitor.running?
                            refute job_monitor.terminated?
                            refute job_monitor.finalized?
                        end
                    end

                    describe "#planning_finished?" do
                        it "is unset when in REACHABLE state" do
                            refute job_monitor.planning_finished?
                        end
                        it "is unset when in planning states" do
                            job_monitor.update_state(states::JOB_PLANNING_READY)
                            refute job_monitor.planning_finished?
                            job_monitor.update_state(states::JOB_PLANNING)
                            refute job_monitor.planning_finished?
                        end
                        it "is set when reaching JOB_PLANNING_FAILED" do
                            job_monitor.update_state(states::JOB_PLANNING_FAILED)
                            assert job_monitor.planning_finished?
                        end
                        it "is set when reaching JOB_READY" do
                            job_monitor.update_state(states::JOB_READY)
                            assert job_monitor.planning_finished?
                        end
                        it "is inferred when receiving a post-READY state" do
                            job_monitor.update_state(states::JOB_SUCCESS)
                            assert job_monitor.planning_finished?
                        end
                    end

                    describe "#running?" do
                        it "is unset when in REACHABLE state" do
                            refute job_monitor.running?
                        end
                        it "is unset when in planning states" do
                            job_monitor.update_state(states::JOB_PLANNING_READY)
                            refute job_monitor.running?
                            job_monitor.update_state(states::JOB_PLANNING)
                            refute job_monitor.running?
                            job_monitor.update_state(states::JOB_PLANNING_FAILED)
                            refute job_monitor.running?
                        end
                        it "is unset when in JOB_READY" do
                            job_monitor.update_state(states::JOB_READY)
                            refute job_monitor.running?
                        end
                        it "is set when in JOB_STARTED" do
                            job_monitor.update_state(states::JOB_STARTED)
                            assert job_monitor.running?
                        end
                        it "is unset when in a terminal state" do
                            job_monitor.update_state(states::JOB_SUCCESS)
                            refute job_monitor.running?
                            job_monitor.update_state(states::JOB_FAILED)
                            refute job_monitor.running?
                            job_monitor.update_state(states::JOB_FINISHED)
                            refute job_monitor.running?
                            job_monitor.update_state(states::JOB_FINALIZED)
                            refute job_monitor.running?
                        end
                    end

                    describe "#success?" do
                        it "is unset when in REACHABLE state" do
                            refute job_monitor.success?
                        end
                        it "is unset if JOB_SUCCESS has not been received" do
                            job_monitor.update_state(states::JOB_READY)
                            refute job_monitor.success?
                            job_monitor.update_state(states::JOB_STARTED)
                            refute job_monitor.success?
                        end
                        it "sets #success? if JOB_SUCCESS is received" do
                            job_monitor.update_state(states::JOB_SUCCESS)
                            assert job_monitor.success?
                        end
                        it "keeps #success? if JOB_SUCCESS is received and other states were received since" do
                            job_monitor.update_state(states::JOB_SUCCESS)
                            job_monitor.update_state(states::JOB_FINISHED)
                            job_monitor.update_state(states::JOB_FINALIZED)
                            assert job_monitor.success?
                        end
                    end

                    describe "#failed?" do
                        it "is unset when in REACHABLE state" do
                            refute job_monitor.failed?
                        end
                        it "is unset if JOB_FAILED has not been received" do
                            job_monitor.update_state(states::JOB_READY)
                            refute job_monitor.failed?
                            job_monitor.update_state(states::JOB_STARTED)
                            refute job_monitor.failed?
                        end
                        it "is set if JOB_FAILED is received" do
                            job_monitor.update_state(states::JOB_FAILED)
                            assert job_monitor.failed?
                        end
                        it "keeps it set if JOB_SUCCESS is received and other states were received since" do
                            job_monitor.update_state(states::JOB_FAILED)
                            job_monitor.update_state(states::JOB_FINISHED)
                            job_monitor.update_state(states::JOB_FINALIZED)
                            assert job_monitor.failed?
                        end
                    end

                    describe "#finished?" do
                        it "is unset when in REACHABLE state" do
                            refute job_monitor.finished?
                        end
                        it "is finished if terminated and if JOB_STARTED was received" do
                            job_monitor.update_state states::JOB_STARTED
                            job_monitor.update_state states::JOB_SUCCESS
                            assert job_monitor.finished?
                        end
                        it "is not finished if terminated but no JOB_STARTED was ever received" do
                            job_monitor.update_state states::JOB_PLANNING_FAILED
                            refute job_monitor.finished?
                        end
                        it "infers that the system ran if the state logically descends from a running state" do
                            job_monitor.update_state states::JOB_FINISHED
                            assert job_monitor.finished?
                        end
                        it "does not infer that the system ran if the state does not logically descend from a running state" do
                            job_monitor.update_state states::JOB_FINALIZED
                            refute job_monitor.finished?
                        end
                    end

                    describe "#terminated?" do
                        it "is unset when in REACHABLE state" do
                            refute job_monitor.terminated?
                        end
                        it "is unset if planning" do
                            job_monitor.update_state states::JOB_PLANNING_READY
                            refute job_monitor.terminated?
                            job_monitor.update_state states::JOB_PLANNING
                            refute job_monitor.terminated?
                        end
                        it "is unset if running" do
                            job_monitor.update_state states::JOB_READY
                            refute job_monitor.terminated?
                            job_monitor.update_state states::JOB_STARTED
                            refute job_monitor.terminated?
                        end
                        it "is set if finished" do
                            job_monitor.update_state states::JOB_FINISHED
                            assert job_monitor.terminated?
                        end
                        it "is set if finalized" do
                            job_monitor.update_state states::JOB_FINALIZED
                            assert job_monitor.terminated?
                        end
                        it "is set if planning failed" do
                            job_monitor.update_state states::JOB_PLANNING_FAILED
                            assert job_monitor.terminated?
                        end
                    end

                    describe "#finalized?" do
                        it "is unset when in REACHABLE state" do
                            refute job_monitor.terminated?
                        end
                        it "is unset in any other state than JOB_FINALIZED" do
                            job_monitor.update_state(states::JOB_STARTED)
                            refute job_monitor.finalized?
                            job_monitor.update_state(states::JOB_SUCCESS)
                            refute job_monitor.finalized?
                        end
                        it "is set when receiving JOB_FINALIZED" do
                            job_monitor.update_state(states::JOB_FINALIZED)
                            assert job_monitor.finalized?
                        end
                    end
                end
            end
        end
    end
end
