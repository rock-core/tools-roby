require 'roby/test/self'

module Roby
    describe Promise do
        attr_reader :recorder
        before do
            @recorder = flexmock
        end
        it "registers the promise as pending work on the engine" do
            p = execution_engine.promise { }
            assert execution_engine.waiting_work.include?(p)
        end

        it "executes the promised work" do
            recorder.should_receive(:called).once
            execution_engine.promise { recorder.called }.execute
            execution_engine.join_all_waiting_work
        end

        it "queues on_success handlers to be executed on the engine" do
            order = Array.new
            execution_engine.
                promise { order << Thread.current }.
                on_success { Thread.pass; order << Thread.current }.
                then { order << Thread.current }.
                execute

            execution_engine.join_all_waiting_work

            assert_equal 3, order.size
            refute_equal Thread.current, order[0]
            assert_equal Thread.current, order[1]
            refute_equal Thread.current, order[2]
        end

        it "optionally executes on_success handlers on the thread pool" do
            order = Array.new
            execution_engine.
                promise { order << Thread.current }.
                on_success(in_engine: false) { Thread.pass; order << Thread.current }.
                then { order << Thread.current }.
                execute

            execution_engine.join_all_waiting_work

            assert_equal 3, order.size
            refute_equal Thread.current, order[0]
            refute_equal Thread.current, order[1]
            refute_equal Thread.current, order[2]
        end

        it "queues on_error handlers to be executed on the engine" do
            order = Array.new
            execution_engine.
                promise { order << Thread.current; raise ArgumentError }.
                on_error { Thread.pass; order << Thread.current }.
                then { order << Thread.current }.
                execute

            execution_engine.join_all_waiting_work

            assert_equal 3, order.size
            refute_equal Thread.current, order[0]
            assert_equal Thread.current, order[1]
            refute_equal Thread.current, order[2]
        end

        it "optionally executes on_error handlers on the thread pool" do
            order = Array.new
            execution_engine.
                promise { order << Thread.current; raise ArgumentError }.
                on_error(in_engine: false) { Thread.pass; order << Thread.current }.
                then { order << Thread.current }.
                execute

            execution_engine.join_all_waiting_work

            assert_equal 3, order.size
            refute_equal Thread.current, order[0]
            refute_equal Thread.current, order[1]
            refute_equal Thread.current, order[2]
        end
    end
end
