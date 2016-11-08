require 'roby/test/self'
require 'roby/app/installer'
require 'roby/app/cucumber/controller'

module Roby
    module App
        module Cucumber
            describe Controller do
                attr_reader :controller, :roby_app_dir
                before do
                    @controller = Controller.new
                    @roby_app_dir = make_tmpdir
                    app = Roby::Application.new
                    app.app_dir = roby_app_dir
                    installer = Roby::Installer.new(app, quiet: true)
                    installer.install
                end

                after do
                    if controller.roby_running?
                        if !controller.roby_connected?
                            controller.roby_connect
                        end
                        controller.roby_stop
                    end
                end

                describe "#roby_start" do
                    it "starts and connects by default" do
                        controller.roby_start('default', 'default', app_dir: roby_app_dir)
                        assert controller.roby_running?
                        assert controller.roby_connected?
                    end

                    it "does not connect if connect: false is given" do
                        controller.roby_start('default', 'default', app_dir: roby_app_dir, connect: false)
                        assert controller.roby_running?
                        refute controller.roby_connected?
                    end

                    it "raises if attempting to start a new controller while one is running" do
                        pid = controller.roby_start('default', 'default', app_dir: roby_app_dir)
                        interface = controller.roby_interface
                        assert_raises(Controller::InvalidState) do
                            controller.roby_start('default', 'default', app_dir: roby_app_dir)
                        end
                        assert_equal pid, controller.roby_pid
                        assert_same interface, controller.roby_interface
                    end
                end

                describe "#roby_stop" do
                    it "stops and joins by default" do
                        controller.roby_start('default', 'default', app_dir: roby_app_dir)
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
                        controller.roby_start('default', 'default', app_dir: roby_app_dir, connect: false)
                        assert_raises(Controller::InvalidState) do
                            controller.roby_stop
                        end
                    end
                end

                describe "#roby_disconnect" do
                    it "disconnects from the remote interface" do
                        controller.roby_start('default', 'default', app_dir: roby_app_dir)
                        controller.roby_disconnect
                        refute controller.roby_connected?
                    end
                    it "allows for a reconnection" do
                        controller.roby_start('default', 'default', app_dir: roby_app_dir)
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
                        controller.roby_start('default', 'default', app_dir: roby_app_dir)
                        controller.roby_disconnect
                        controller.roby_interface.attempt_connection
                        controller.roby_interface.wait_connection_attempt_result
                        assert controller.roby_try_connect
                    end

                    it "returns true if it is already connected" do
                        controller.roby_start('default', 'default', app_dir: roby_app_dir)
                        assert controller.roby_try_connect
                    end
                end

                describe "#roby_running?" do
                    it "returns false if the controller has not been started" do
                        refute controller.roby_running?
                    end

                    it "returns true if the controller has been started" do
                        controller.roby_start('default', 'default', app_dir: roby_app_dir, connect: false)
                        assert controller.roby_running?
                    end
                end

                describe "#roby_connected?" do
                    it "returns false if the controller has not been started" do
                        refute controller.roby_connected?
                    end

                    it "returns false if the controller has been started and the we're not connected" do
                        controller.roby_start('default', 'default', app_dir: roby_app_dir, connect: false)
                        refute controller.roby_connected?
                    end

                    it "returns true if we're connected" do
                        controller.roby_start('default', 'default', app_dir: roby_app_dir, connect: false)
                        controller.roby_connect
                        assert controller.roby_connected?
                    end

                    it "returns false if the remote host is stopped" do
                        controller.roby_start('default', 'default', app_dir: roby_app_dir, connect: false)
                        controller.roby_connect
                        controller.roby_stop(join: false)
                        refute controller.roby_connected?
                        # Join to please the after block
                        controller.roby_join
                    end

                    it "returns false if we've called #roby_stop and joined" do
                        controller.roby_start('default', 'default', app_dir: roby_app_dir, connect: false)
                        controller.roby_connect
                        controller.roby_stop
                        refute controller.roby_connected?
                    end
                end

                describe "handling of actions" do
                    before do
                        File.open(File.join(roby_app_dir, 'config', 'robots', 'default.rb'), 'w') do |io|
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
                            end
                            Robot.actions { use_library CucumberTestActions }
                            EOACTION
                        end
                        controller.roby_start('default', 'default', app_dir: roby_app_dir)
                    end

                    def poll_interface_until(timeout: 10)
                        deadline = Time.now + timeout
                        remaining_timeout = timeout
                        while !yield
                            controller.roby_interface.wait(timeout: remaining_timeout)
                            controller.roby_interface.poll
                            remaining_timeout = deadline - Time.now
                            if remaining_timeout < 0
                                flunk("timed out waiting in poll_interface_until")
                            end
                        end
                    end

                    describe "#start_monitoring_job" do
                        it "runs the action on the remote controller" do
                            controller.start_monitoring_job('cucumber test job', 'cucumber_monitoring')
                            jobs = controller.roby_interface.client.each_job.to_a
                            assert_equal "CucumberTestTask", jobs.first.placeholder_task.model.name
                            assert_equal 10, jobs.first.placeholder_task.arg
                        end
                        it "passes arguments to the action" do
                            controller.start_monitoring_job('cucumber test job', 'cucumber_monitoring', arg: 20)
                            jobs = controller.roby_interface.client.each_job.to_a
                            assert_equal Hash[arg: 20], jobs.first.task.action_arguments
                        end
                    end

                    describe "#run_job" do
                        it "runs the action and waits for it to end" do
                            controller.run_job('cucumber_action', task_success: true)
                            assert controller.roby_interface.client.each_job.to_a.empty?
                        end
                        it "raises FailedAction if the action failed" do
                            assert_raises(Controller::FailedAction) do
                                controller.run_job('cucumber_action', task_fail: true)
                            end
                        end
                        it "fails if an active monitor job failed" do
                            action = controller.start_monitoring_job(
                                'cucumber test job', 'cucumber_monitoring', task_fail: true)
                            poll_interface_until { action.failed? }
                            assert_raises(Controller::FailedBackgroundJob) do
                                controller.run_job('cucumber_action')
                            end
                        end
                        it "drops the job if a monitor failed" do
                            action = controller.start_monitoring_job(
                                'cucumber test job', 'cucumber_monitoring', task_fail: true)
                            poll_interface_until { action.failed? }
                            assert_raises(Controller::FailedBackgroundJob) do
                                controller.run_job('cucumber_action')
                            end
                            poll_interface_until do
                                controller.roby_interface.client.each_job.to_a.empty?
                            end
                        end
                        it "drops the active monitors if the job finishes successfully" do
                            action = controller.start_monitoring_job(
                                'cucumber test job', 'cucumber_monitoring')
                            controller.run_job('cucumber_action', task_success: true)
                            assert controller.background_jobs.empty?
                            poll_interface_until do
                                controller.roby_interface.client.each_job.to_a.empty?
                            end
                        end
                        it "drops the active monitors if the job fails" do
                            action = controller.start_monitoring_job(
                                'cucumber test job', 'cucumber_monitoring')
                            assert_raises(Controller::FailedAction) do
                                controller.run_job('cucumber_action', task_fail: true)
                            end
                            assert controller.background_jobs.empty?
                            poll_interface_until do
                                controller.roby_interface.client.each_job.to_a.empty?
                            end
                        end
                        it "ignores monitoring actions that finished successfully" do
                            action = controller.start_monitoring_job(
                                'cucumber test job', 'cucumber_monitoring', task_success: true)
                            poll_interface_until { action.success? }
                            controller.run_job('cucumber_action', task_success: true)
                        end
                        it "does not stop background jobs" do
                            action = controller.start_job(
                                'cucumber test job', 'cucumber_monitoring')
                            controller.run_job('cucumber_action', task_success: true)
                            job = controller.roby_interface.client.each_job.first
                            assert_equal 1, job.job_id
                        end
                    end
                end
            end
        end
    end
end

