# frozen_string_literal: true

require "roby/test/self"

module Roby
    describe Event do
        describe "source-related functionality" do
            before do
                generator = EventGenerator.new
                @event = Event.new(generator, 1, [])
            end

            it "adds refs to the given sources" do
                sources = 3.times.map { flexmock }
                @event.add_sources(sources[0, 1])
                @event.add_sources(sources[1, 2])

                assert_equal sources.to_set, @event.sources
            end

            # Helper that creates an object deep in the call chain to more or less
            # guarantee its garbage-collection
            def recursive_add_source(event, klass, level)
                if level == 0
                    event.add_sources([object = klass.new])
                    WeakRef.new(object)
                else
                    recursive_add_source(event, klass, level - 1)
                end
            end

            it "automatically removes garbage-collected sources" do
                GC.disable
                refs = 1_000.times.map do |i|
                    recursive_add_source(@event, Object, i)
                end
                GC.start
                objects = refs.find_all(&:weakref_alive?).map(&:__getobj__)
                assert_equal objects.size, @event.sources.size
                assert objects.size < 1_000
            ensure
                GC.enable
            end

            it "handles refs whose object have been recycled colliding " \
               "with objects being added" do
                collide_me = Class.new do
                    def hash
                        10
                    end
                end

                # Yes. This happened in a test run. Never seen it in the wild, though.
                # But it is possible.
                #
                # Note that writing this test, I also got a problem while cleaning
                # up @sources, which was a set at the time. Set#delete_if finds the
                # objects to delete, and then deletes, which forces the hash to re-hash
                # the argument and boom

                GC.disable
                1_000.times.map do |i|
                    recursive_add_source(@event, collide_me, i)
                end
                GC.start
                @event.add_sources([object = collide_me.new])
                assert @event.sources.include?(object)
                assert @event.sources.size < 1_001
            end
        end
    end
end
