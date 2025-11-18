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

                describe "marshalling of TaskEventGenerator" do
                    it "marshals it" do
                        task = Roby::Tasks::Simple.new
                        marshalled = @channel.marshal_filter_object(task.start_event)
                        assert_equal @channel.marshal_filter_object(task), marshalled.task
                        assert_equal :start, marshalled.symbol
                    end

                    it "displays a terse string with to_s" do
                        generator = Roby::Tasks::Simple.new(id: 42).start_event
                        marshalled = @channel.marshal_filter_object(generator)
                        assert_equal generator.to_s, marshalled.to_s
                    end

                    it "displays extensive info in pretty_print" do
                        generator = Roby::Tasks::Simple.new(id: 42).start_event
                        marshalled = @channel.marshal_filter_object(generator)
                        assert_equal PP.pp(generator, +"", 0), PP.pp(marshalled, +"", 0)
                    end
                end

                describe "marshalling of TaskEvent" do
                    before do
                        @task = Roby::Tasks::Simple.new
                        @generator = @task.start_event
                        @time = Time.utc(1980, 9, 30, 11, 20, 32)
                        @event = @generator.new([42], 32, @time)
                        @marshalled = @channel.marshal_filter_object(@event)
                    end

                    it "marshals it" do
                        assert_equal @channel.marshal_filter_object(@generator),
                                     @marshalled.generator
                        assert_equal @time, @marshalled.time
                        assert_equal [42], @marshalled.context
                        assert_equal 32, @marshalled.propagation_id
                    end

                    it "displays a terse string with to_s" do
                        assert_equal @event.to_s, @marshalled.to_s
                    end

                    it "displays extensive info in pretty_print" do
                        assert_equal PP.pp(@event, +"", 0), PP.pp(@marshalled, +"", 0)
                    end
                end
            end
        end
    end
end
