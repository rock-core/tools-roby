# frozen_string_literal: true

require "roby/test/self"
require "roby/interface/v2"

module Roby
    module Interface
        module V2
            describe Protocol do
                before do
                    @io_r, @io_w = Socket.pair(:UNIX, :STREAM, 0)
                    @channel = Channel.new(@io_r, true)
                end
                after do
                    @io_r.close unless @io_r.closed?
                    @io_w.close unless @io_w.closed?
                end

                describe "marshalling of DelayedArgumentFromState" do
                    it "marshals a delayed argument from State" do
                        obj = Roby.from_state.some.arg
                        marshalled = @channel.marshal_filter_object(obj)
                        assert_equal :State, marshalled.object
                        assert_equal %I[some arg], marshalled.path
                    end

                    it "marshals a delayed argument from Conf" do
                        obj = Roby.from_conf.some.arg
                        marshalled = @channel.marshal_filter_object(obj)
                        assert_equal :Conf, marshalled.object
                        assert_equal %I[some arg], marshalled.path
                    end

                    it "marshals a delayed argument from an arbitrary object" do
                        o = OpenStruct.new
                        obj = DelayedArgumentFromState.new(o).some.arg
                        marshalled = @channel.marshal_filter_object(obj)
                        assert_equal o.to_s, marshalled.object
                        assert_equal %I[some arg], marshalled.path
                    end
                end
            end
        end
    end
end
