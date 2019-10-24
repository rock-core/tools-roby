# frozen_string_literal: true

require 'roby/test/self'
require 'roby/interface/rest'

module Roby
    module Interface
        module REST
            describe Server do
                before do
                    @app = Roby::Application.new
                end

                after do
                    if @server&.running?
                        @server.wait_start
                        @server.stop
                    end

                    EventMachine.stop if EventMachine.reactor_running?
                end

                describe '#running?' do
                    before do
                        @server = REST::Server.new(@app, port: 0)
                    end
                    it 'returns false before the call to #start' do
                        refute @server.running?
                    end
                    it 'returns true just after #start' do
                        @server.start(wait_timeout: 0)
                        assert @server.running?
                    end
                    it 'returns false after being stopped and joined' do
                        @server.start(wait_timeout: 0)
                        @server.stop
                        refute @server.running?
                    end
                end

                describe 'the start timeout behavior' do
                    it 'does not wait at all if the start timeout is zero' do
                        @server = REST::Server.new(@app, port: 0)
                        flexmock(@server).should_receive(:wait_start).never
                        @server.start(wait_timeout: 0)
                    end

                    it 'raises if the thread is not functional after '\
                       'the alloted timeout' do
                        @server = REST::Server.new(@app, port: 0)
                        flexmock(@server).should_receive(:create_thin_thread)
                                         .and_return { Thread.new {} }
                        assert_raises(REST::Server::Timeout) do
                            @server.start(wait_timeout: 0.01)
                        end
                    end
                end

                describe 'over TCP' do
                    describe 'a given port of zero' do
                        before do
                            @server = REST::Server.new(@app, port: 0)
                        end

                        it 'spawns a working server and waits for it to be functional' do
                            @server.start
                            assert @server.server_alive?
                        end

                        describe '#port' do
                            it 'returns the port right away if the server is started '\
                               'and synchronized' do
                                @server.start
                                refute_equal 0, @server.port(timeout: 0)
                            end
                            it 'waits for the port to be available '\
                               'if the server is started' do
                                @server.start(wait_timeout: 0)
                                refute_equal 0, @server.port(timeout: 1)
                            end
                            it 'times out if the server is not yet started' do
                                assert_raises(REST::Server::Timeout) do
                                    @server.port
                                end
                            end
                            it 'returns the actual port if the server has been started '\
                               'and then stopped' do
                                @server.start
                                @server.stop
                                refute_equal 0, @server.port
                            end
                        end
                    end

                    describe 'a nonzero port' do
                        before do
                            server = ::TCPServer.new(0)
                            @port = server.local_address.ip_port
                            server.close
                            @server = REST::Server.new(@app, port: @port)
                        end

                        it 'spawns a working server and waits for it to be functional' do
                            @server.start
                            assert @server.server_alive?
                        end

                        describe '#port' do
                            it 'returns the port if the server is not yet started' do
                                assert_equal @port, @server.port
                            end

                            it 'returns the port if the server is started but we did '\
                               'not synchronize' do
                                @server.start(wait_timeout: 0)
                                assert_equal @port, @server.port
                            end

                            it 'returns the port if the server is started '\
                               'and synchronized' do
                                @server.start
                                assert_equal @port, @server.port
                            end

                            it 'returns the port if the server is started and stopped' do
                                @server.start
                                @server.stop
                                assert_equal @port, @server.port
                            end
                        end
                    end
                end
            end
        end
    end
end
