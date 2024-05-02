# frozen_string_literal: true

require "roby/test/self"
require "roby/cli/gen_main"
require "roby/app/cucumber/controller"

module Roby
    module App
        module Cucumber
            describe Controller do
                attr_reader :controller, :roby_app_dir, :roby_log_dir

                before do
                    @controller = Controller.new(port: 0)
                    @roby_app_dir = make_tmpdir
                    @roby_log_dir = make_tmpdir
                    Dir.chdir(roby_app_dir) { CLI::GenMain.start(["app", "--quiet"]) }
                end

                after do
                    ensure_roby_controller_stopped
                end

                def ensure_roby_controller_stopped
                    return unless controller.roby_running?

                    unless controller.roby_connected?
                        begin
                            controller.roby_connect(timeout: 1)
                        rescue Controller::ConnectionTimeout # rubocop:disable Lint/SuppressedException
                        end
                    end

                    if controller.roby_connected?
                        controller.roby_stop
                    else
                        controller.roby_kill
                    end
                end

                def roby_start(*args, log_dir: roby_log_dir, quiet: false, **options)
                    redirection =
                        if quiet
                            { out: "/dev/null", err: "/dev/null" }
                        else
                            {}
                        end

                    controller.roby_start(
                        *args, log_dir: log_dir, **redirection, **options
                    )
                end

                describe "#roby_start" do
                    it "starts and connects by default" do
                        roby_start("default", "default", app_dir: roby_app_dir)
                        assert controller.roby_running?
                        assert controller.roby_connected?
                    end

                    it "does not connect if connect: false is given" do
                        roby_start("default", "default",
                                   app_dir: roby_app_dir, connect: false)
                        assert controller.roby_running?
                        refute controller.roby_connected?
                    end

                    it "raises if attempting to start a new controller "\
                       "while one is running" do
                        pid = roby_start("default", "default", app_dir: roby_app_dir)
                        interface = controller.roby_interface
                        assert_raises(Controller::InvalidState) do
                            roby_start("default", "default", app_dir: roby_app_dir)
                        end
                        assert_equal pid, controller.roby_pid
                        assert_same interface, controller.roby_interface
                    end
                end

                describe "#roby_log_dir" do
                    it "returns the app's log dir" do
                        log_dir = make_tmpdir
                        roby_start("default", "default",
                                   app_dir: roby_app_dir, log_dir: log_dir)
                        assert_equal log_dir, controller.roby_log_dir
                    end
                end

                describe "#roby_stop" do
                    it "stops and joins by default" do
                        roby_start("default", "default", app_dir: roby_app_dir)
                        controller.roby_stop
                        refute controller.roby_running?
                        refute controller.roby_connected?
                    end

                    it "raises if the controller is not running" do
                        assert_raises(Controller::InvalidState) do
                            controller.roby_stop
                        end
                    end

                    it "raises if the controller is not connected" do
                        roby_start("default", "default",
                                   app_dir: roby_app_dir, connect: false)
                        assert_raises(Controller::InvalidState) do
                            controller.roby_stop
                        end
                    end

                    it "is uses the INT signal if the controller does not stop" do
                        robot_default_path =
                            File.join(roby_app_dir, "config", "robots", "default.rb")
                        File.open(robot_default_path, "w") do |io|
                            io.puts <<-ROBOT_CONFIG
                            at_exit { sleep }
                            ROBOT_CONFIG
                        end
                        roby_start("default", "default", app_dir: roby_app_dir)
                        controller.roby_stop(join_timeout: 1)
                    end

                    it "falls back to KILL if INT is not enough" do
                        robot_default_path =
                            File.join(roby_app_dir, "config", "robots", "default.rb")
                        File.open(robot_default_path, "w") do |io|
                            io.puts <<-ROBOT_CONFIG
                            at_exit do
                                loop do
                                    begin
                                        sleep
                                    rescue Interrupt
                                    end
                                end
                            end
                            ROBOT_CONFIG
                        end
                        roby_start("default", "default", app_dir: roby_app_dir)
                        controller.roby_stop(join_timeout: 1)
                    end
                end

                describe "#roby_disconnect" do
                    it "disconnects from the remote interface" do
                        roby_start("default", "default", app_dir: roby_app_dir)
                        controller.roby_disconnect
                        refute controller.roby_connected?
                    end
                    it "allows for a reconnection" do
                        roby_start("default", "default", app_dir: roby_app_dir)
                        controller.roby_disconnect
                        controller.roby_connect
                        assert controller.roby_connected?
                    end
                end

                describe "#roby_try_connect" do
                    it "returns nil if the interface cannot connect" do
                        refute controller.roby_try_connect
                    end

                    it "returns true if it is connected" do
                        roby_start("default", "default", app_dir: roby_app_dir)
                        controller.roby_disconnect
                        controller.roby_interface.attempt_connection
                        controller.roby_interface.wait_connection_attempt_result
                        assert controller.roby_try_connect
                    end

                    it "returns true if it is already connected" do
                        roby_start("default", "default", app_dir: roby_app_dir)
                        assert controller.roby_try_connect
                    end
                end

                describe "#roby_running?" do
                    it "returns false if the controller has not been started" do
                        refute controller.roby_running?
                    end

                    it "returns true if the controller has been started" do
                        roby_start("default", "default",
                                   app_dir: roby_app_dir, connect: false)
                        assert controller.roby_running?
                    end
                end

                describe "#roby_connected?" do
                    it "returns false if the controller has not been started" do
                        refute controller.roby_connected?
                    end

                    it "returns false if the controller has been started "\
                       "and the we're not connected" do
                        roby_start("default", "default",
                                   app_dir: roby_app_dir, connect: false)
                        refute controller.roby_connected?
                    end

                    it "returns true if we're connected" do
                        roby_start("default", "default",
                                   app_dir: roby_app_dir, connect: false)
                        controller.roby_connect
                        assert controller.roby_connected?
                    end

                    it "returns false if the remote host is stopped" do
                        roby_start("default", "default",
                                   app_dir: roby_app_dir, connect: false)
                        controller.roby_connect
                        controller.roby_stop(join: false)
                        refute controller.roby_connected?
                        # Join to please the after block
                        controller.roby_join
                    end

                    it "returns false if we've called #roby_stop and joined" do
                        roby_start("default", "default",
                                   app_dir: roby_app_dir, connect: false)
                        controller.roby_connect
                        controller.roby_stop
                        refute controller.roby_connected?
                    end
                end

                describe "handling of actions" do
                    before do
                        robot_default_path =
                            File.join(roby_app_dir, "config", "robots", "default.rb")
                        File.open(robot_default_path, "w") do |io|
                            io.puts <<-EOACTION
                            class CucumberTestTask < Roby::Task
                                argument :arg, default: 10
                                argument :task_fail, default: false
                                argument :task_success, default: false
                                terminates

                                on :start do |event|
                                    if task_fail
                                        raise "failed because task_fail=true"
                                    elsif task_success
                                        success_event.emit
                                    end
                                end
                            end
                            class CucumberTestActions < Roby::Actions::Interface
                                describe('the test monitor').
                                    optional_arg('fail', 'whether the action should fail').
                                    optional_arg('task_fail', 'whether the action\\'s task should fail').
                                    optional_arg('task_success', 'whether the action\\'s task should success after startup').
                                    optional_arg('arg', 'the task argument').
                                    returns(CucumberTestTask)
                                def cucumber_monitoring(arguments = Hash.new)
                                    if arguments.delete(:fail)
                                        raise "failing the action"
                                    end
                                    CucumberTestTask.new(arguments)
                                end

                                describe('the test action').
                                    optional_arg('fail', 'whether the action should fail').
                                    optional_arg('task_fail', 'whether the action\\'s task should fail').
                                    optional_arg('task_success', 'whether the action\\'s task should success after startup').
                                    optional_arg('arg', 'the task argument').
                                    returns(CucumberTestTask)
                                def cucumber_action(arguments = Hash.new)
                                    CucumberTestTask.new(arguments)
                                end

                                describe('a test action with required argument').
                                    required_arg('req', '')
                                def cucumber_action_with_required_argument(arguments)
                                end
                            end
                            Robot.init do
                                require 'roby/schedulers/temporal'
                                Roby.scheduler = Roby::Schedulers::Temporal.new
                            end
                            Robot.actions { use_library CucumberTestActions }
                            EOACTION
                        end
                        roby_start("default", "default", app_dir: roby_app_dir)
                        controller.roby_enable_backtrace_filtering(enable: false)
                    end

                    def poll_interface_until(timeout: 10)
                        deadline = Time.now + timeout
                        remaining_timeout = timeout
                        until yield
                            controller.roby_interface.wait(timeout: remaining_timeout)
                            controller.roby_interface.poll
                            remaining_timeout = deadline - Time.now
                            if remaining_timeout < 0
                                raise "timed out waiting in poll_interface_until"
                            end
                        end
                    end

                    describe "#start_job" do
                        it "queues the action on the remote controller "\
                           "until the next apply_current_batch" do
                            controller.start_job(
                                "cucumber test job", "cucumber_monitoring"
                            )
                            assert controller.roby_interface.client.each_job.to_a.empty?
                            controller.apply_current_batch

                            jobs = controller.roby_interface.client.each_job.to_a
                            assert_equal "CucumberTestTask",
                                         jobs.first.placeholder_task.model.name
                            assert_equal 10, jobs.first.placeholder_task.arg
                        end
                        it "drops all main jobs after a run_job" do
                            controller.start_job(
                                "cucumber test job", "cucumber_monitoring", arg: 1
                            )
                            controller.run_job("cucumber_action", task_success: true)
                            controller.start_job(
                                "cucumber test job", "cucumber_monitoring", arg: 2
                            )
                            controller.apply_current_batch
                            jobs = controller.roby_interface.client.each_job.to_a
                            assert_equal([2], jobs.map { |t| t.placeholder_task.arg })
                        end
                        it "does allow to queue new jobs again after a run_job" do
                            controller.start_job(
                                "cucumber test job", "cucumber_monitoring", arg: 1
                            )
                            controller.run_job("cucumber_action", task_success: true)
                            controller.start_job(
                                "cucumber test job", "cucumber_monitoring", arg: 2
                            )
                            controller.start_job(
                                "cucumber test job", "cucumber_monitoring", arg: 3
                            )
                            controller.apply_current_batch
                            jobs = controller.roby_interface.client.each_job.to_a
                            assert_equal [2, 3],
                                         jobs.map { |t| t.placeholder_task.arg }.sort
                        end
                        it "passes arguments to the action" do
                            controller.start_job(
                                "cucumber test job", "cucumber_monitoring", arg: 20
                            )
                            controller.apply_current_batch
                            jobs = controller.roby_interface.client.each_job.to_a
                            assert_equal 20, jobs.first.placeholder_task.arg
                        end
                        it "registers the job as a main job" do
                            job = controller.start_job(
                                "cucumber test job", "cucumber_monitoring", arg: 20
                            )
                            controller.apply_current_batch
                            assert_equal [job],
                                         controller.each_main_job.map(&:action_monitor)
                        end
                        describe "the validation mode" do
                            before do
                                controller.validation_mode = true
                            end
                            it "does not actually queue the action" do
                                flexmock(controller.roby_interface.client)
                                    .should_receive(:process_batch).never
                                flexmock(controller).should_receive(:validate_job)
                                controller.start_job("", flexmock, flexmock)
                                controller.apply_current_batch
                            end
                            it "validates the action" do
                                flexmock(controller)
                                    .should_receive(:validate_job)
                                    .with(:action_name, action_arguments = flexmock)
                                controller.start_job("", :action_name, action_arguments)
                                controller.apply_current_batch
                            end
                        end
                    end

                    describe "#start_monitoring_job" do
                        it "runs the action on the remote controller" do
                            controller.start_monitoring_job(
                                "cucumber test job", "cucumber_monitoring"
                            )
                            assert controller.roby_interface.client.each_job.to_a.empty?
                            controller.apply_current_batch
                            jobs = controller.roby_interface.client.each_job.to_a
                            assert_equal "CucumberTestTask",
                                         jobs.first.placeholder_task.model.name
                            assert_equal 10, jobs.first.placeholder_task.arg
                        end
                        it "passes arguments to the action" do
                            controller.start_monitoring_job(
                                "cucumber test job", "cucumber_monitoring", arg: 20
                            )
                            controller.apply_current_batch
                            jobs = controller.roby_interface.client.each_job.to_a
                            assert_equal({ arg: 20 }, jobs.first.task.action_arguments)
                        end
                        it "registers the job as a monitoring job" do
                            job = controller.start_monitoring_job(
                                "cucumber test job", "cucumber_monitoring", arg: 20
                            )
                            controller.apply_current_batch
                            assert_equal [job],
                                         controller.each_monitoring_job
                                                   .map(&:action_monitor)
                        end
                        describe "the validation mode" do
                            before do
                                controller.validation_mode = true
                            end
                            it "does not actually start the action" do
                                flexmock(controller.roby_interface.client)
                                    .should_receive(:process_batch).never
                                flexmock(controller).should_receive(:validate_job)
                                controller.start_monitoring_job("", flexmock, flexmock)
                                controller.apply_current_batch
                            end
                            it "validates the action" do
                                flexmock(controller)
                                    .should_receive(:validate_job)
                                    .with(:action_name, action_arguments = flexmock)
                                controller.start_monitoring_job(
                                    "", :action_name, action_arguments
                                )
                                controller.apply_current_batch
                            end
                        end
                    end

                    describe "#run_job" do
                        it "runs the action in the current batch "\
                           "and waits for it to end" do
                            flexmock(controller).should_receive(:apply_current_batch)
                                                .once.pass_thru
                            controller.run_job("cucumber_action", task_success: true)
                            assert controller.roby_interface.client.each_job.to_a.empty?
                        end
                        it "raises FailedAction if the action failed" do
                            assert_raises(Controller::FailedAction) do
                                controller.run_job("cucumber_action", task_fail: true)
                            end
                        end
                        it "fails if an active monitor job failed" do
                            action = controller.start_monitoring_job(
                                "cucumber test job", "cucumber_monitoring",
                                task_fail: true
                            )
                            controller.apply_current_batch
                            poll_interface_until { action.failed? }
                            assert_raises(Controller::FailedBackgroundJob) do
                                controller.run_job("cucumber_action")
                            end
                        end
                        it "drops the job if a monitor failed" do
                            action = controller.start_monitoring_job(
                                "cucumber test job", "cucumber_monitoring",
                                task_fail: true
                            )
                            controller.apply_current_batch
                            poll_interface_until { action.failed? }
                            assert_raises(Controller::FailedBackgroundJob) do
                                controller.run_job("cucumber_action")
                            end
                            controller.apply_current_batch
                            poll_interface_until do
                                controller.roby_interface.client.each_job.to_a.empty?
                            end
                        end
                        it "drops the active monitors if the job finishes successfully" do
                            controller.start_monitoring_job(
                                "cucumber test job", "cucumber_monitoring"
                            )
                            controller.run_job("cucumber_action", task_success: true)
                            controller.apply_current_batch
                            assert controller.background_jobs.empty?
                            poll_interface_until do
                                controller.roby_interface.client.each_job.to_a.empty?
                            end
                        end
                        it "drops the active monitors if the job fails" do
                            controller.start_monitoring_job(
                                "cucumber test job", "cucumber_monitoring"
                            )
                            assert_raises(Controller::FailedAction) do
                                controller.run_job("cucumber_action", task_fail: true)
                            end
                            controller.apply_current_batch
                            assert controller.background_jobs.empty?
                            poll_interface_until do
                                controller.roby_interface.client.each_job.to_a.empty?
                            end
                        end
                        it "ignores monitoring actions that finished successfully" do
                            action = controller.start_monitoring_job(
                                "cucumber test job", "cucumber_monitoring",
                                task_success: true
                            )
                            controller.apply_current_batch
                            poll_interface_until { action.success? }
                            controller.run_job("cucumber_action", task_success: true)
                        end
                        it "does not stop background jobs" do
                            controller.start_job(
                                "cucumber test job", "cucumber_monitoring"
                            )
                            controller.run_job("cucumber_action", task_success: true)
                            controller.apply_current_batch
                            job = controller.roby_interface.client.each_job.first
                            assert_equal 1, job.job_id
                        end
                    end
                end
            end
        end
    end
end
