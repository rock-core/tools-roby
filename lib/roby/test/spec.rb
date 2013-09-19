module Roby
    module Test
        class Spec < MiniTest::Spec
            include Test::Assertions

            def plan; Roby.plan end
            def engine; Roby.plan.engine end

            def setup
                super

                @watch_events_handler_id = engine.add_propagation_handler(:type => :external_events) do |plan|
                    Test.verify_watched_events
                end
            end

            def teardown
                super
                if @watch_events_handler_id
                    engine.remove_propagation_handler(@watch_events_handler_id)
                end
            end
        end
    end
end

