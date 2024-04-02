# frozen_string_literal: true

require "roby/test/self"
require "roby/interface/v2/async"
require "roby/interface/v2/tcp"
require_relative "client_server_test_helpers"

module Roby
    module Interface
        module V2
            module Async
                describe ActionMonitor do
                    include ClientServerTestHelpers

                    attr_reader :client, :server, :mock_jobs

                    before do
                        @server = create_server
                        @client = connect(server)
                        @mock_jobs = []
                        flexmock(client, :strict).should_receive(:jobs).and_return { mock_jobs }
                    end

                    subject do
                        process_call do
                            ActionMonitor.new(client, "test", id: 20)
                        end
                    end

                    def create_mock_job(job_id, action_name, **action_arguments)
                        job = flexmock(:on, JobMonitor,
                                       job_id: job_id, action_name: action_name.to_s, action_arguments: action_arguments)
                        job.should_receive(:on_progress).by_default
                        job.should_receive(:start).by_default
                        mock_jobs << job
                        job
                    end

                    def assert_client_receives_batch(*calls)
                        batch = nil
                        flexmock(client.client, :strict).should_receive(:process_batch)
                            .once.with(->(b) { batch = b })
                        yield
                        assert batch
                        assert_equal calls, batch.__calls
                    end

                    describe "#initialize" do
                        it "binds itself to an existing job if there's one, and starts the job monitor" do
                            job = create_mock_job(42, "test", id: 20)
                            job.should_receive(:start).once
                            assert_same job, subject.async
                        end

                        it "filters out on the static arguments" do
                            job = create_mock_job(42, "test", id: 30)
                            job.should_receive(:start).never
                            assert !subject.async
                        end
                    end

                    describe "a monitor without an actual job" do
                        it "is not running" do
                            assert !subject.running?
                        end
                        it "is not terminated" do
                            assert !subject.terminated?
                        end
                        it "returns a nil #job_id" do
                            assert !subject.job_id
                        end

                        it "raises InvalidState in #kill" do
                            assert_raises(InvalidState) { subject.kill }
                        end
                    end

                    describe "a monitor with a job" do
                        attr_reader :job

                        before do
                            @job = create_mock_job(42, "test", id: 20)
                        end
                        describe "#running?" do
                            it "returns false if the attached job is not running" do
                                job.should_receive(:running?).and_return(false)
                                assert !subject.running?
                            end
                            it "returns true if the attached job is running" do
                                job.should_receive(:running?).and_return(true)
                                assert subject.running?
                            end
                        end

                        describe "#kill" do
                            it "raises InvalidState if called on a non-running action" do
                                job.should_receive(:running?).and_return(false)
                                assert_raises(InvalidState) { subject.kill }
                            end

                            it "kills the job" do
                                job.should_receive(:running?).and_return(true)
                                assert_client_receives_batch [[], :kill_job, 42] do
                                    subject.kill
                                end
                            end

                            it "adds the kill command to a batch if given one, and does not process it" do
                                job.should_receive(:running?).and_return(true)
                                batch = flexmock(:on, Client::BatchContext)
                                batch.should_receive(:kill_job).with(42).once
                                subject.kill(batch: batch)
                            end
                        end

                        describe "#terminated?" do
                            it "is false if the job is not terminated" do
                                job.should_receive(:terminated?).and_return(false)
                                assert !subject.terminated?
                            end
                            it "is true if the job is terminated" do
                                job.should_receive(:terminated?).and_return(true)
                                assert subject.terminated?
                            end
                        end
                    end

                    describe "#restart" do
                        it "simply starts the job if there are no running jobs" do
                            flexmock(client.client, :strict).should_receive(:has_action?).with("test").and_return(true)
                            assert_client_receives_batch [[], :start_job, "test", { id: 20 }] do
                                subject.restart
                            end
                        end
                        it "kills and starts the job if there is one running" do
                            job = create_mock_job(42, "test", id: 20)
                            job.should_receive(:running?).and_return(true)
                            flexmock(client.client, :strict).should_receive(:has_action?).with("test").and_return(true)
                            assert_client_receives_batch [[], :kill_job, 42], [[], :start_job, "test", { id: 20 }] do
                                subject.restart
                            end
                        end
                    end
                end
            end
        end
    end
end
