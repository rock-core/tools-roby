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
            end
        end
    end
end

