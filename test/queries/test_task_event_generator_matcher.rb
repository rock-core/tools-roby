# frozen_string_literal: true

require 'roby/test/self'
require 'roby/tasks/simple'

module Roby
    module Queries
        describe TaskEventGeneratorMatcher do
            attr_reader :task_matcher, :task, :generator, :source_generator, :symbol_match
            before do
                @task_matcher = flexmock
                plan.add(@task = Roby::Task.new)
                @generator = task.stop_event

                plan.add(other_task = Roby::Task.new)
                @source_generator = other_task.failed_event
                other_task.stop_event.forward_to task.stop_event
                task_matcher.should_receive(:===).with(other_task).and_return(false)
            end

            describe 'not in generalized mode' do
                describe '#===' do
                    def create_matcher(*args)
                        Roby::Queries::TaskEventGeneratorMatcher.new(task_matcher, *args)
                    end

                    it 'returns false for a plain event generator' do
                        plan.add(generator = Roby::EventGenerator.new)
                        refute create_matcher === generator
                    end

                    it 'returns false if the task matcher returns false' do
                        task_matcher.should_receive(:===).with(task).and_return(false)
                        refute create_matcher === generator
                    end
                    it 'returns true if the task matcher returns true and '\
                    'the symbol match is default' do
                        task_matcher.should_receive(:===).with(task).and_return(true)
                        assert create_matcher === generator
                    end
                    it 'should return false if the task matcher returns true '\
                    'but the symbol does not match' do
                        task_matcher.should_receive(:===).with(task).and_return(true)
                        refute create_matcher('bla') === generator
                    end
                    it 'returns true if the task matcher returns true '\
                       'and the symbol matches' do
                        task_matcher.should_receive(:===).with(task).and_return(true)
                        symbol_match = flexmock
                        symbol_match.should_receive(:===).with('stop').and_return(true)
                        assert create_matcher(symbol_match) === generator
                    end
                    it 'returns false if it is forwarded to another task for which '\
                    'the task matcher returns false' do
                        task_matcher.should_receive(:===).with(task).and_return(false)
                        refute create_matcher === source_generator
                    end
                    it 'returns false if it is forwarded to another task for which '\
                    'the task matcher returns true and the symbol match is default' do
                        task_matcher.should_receive(:===).with(task).and_return(true)
                        refute create_matcher === source_generator
                    end
                    it 'returns false if it is forwarded to another task for which '\
                    'the task matcher returns true but the symbol does not match' do
                        task_matcher.should_receive(:===).with(task).and_return(true)
                        refute create_matcher('bla') === source_generator
                    end
                    it 'returns false if it is forwarded to another task for which '\
                    'the task matcher returns true and the symbol matches' do
                        task_matcher.should_receive(:===).with(task).and_return(true)
                        @symbol_match = flexmock
                        symbol_match.should_receive(:===).with('failed').and_return(false)
                        symbol_match.should_receive(:===).with('failed').and_return(false)
                        symbol_match.should_receive(:===).with('stop').and_return(true)
                        refute create_matcher(symbol_match) === source_generator
                    end
                end
            end

            describe 'in generalized mode' do
                describe '#===' do
                    def create_matcher(*args)
                        Roby::Queries::TaskEventGeneratorMatcher
                            .new(task_matcher, *args)
                            .generalized
                    end

                    it 'returns false for a plain event generator' do
                        plan.add(generator = Roby::EventGenerator.new)
                        refute create_matcher === generator
                    end
                    it 'returns false for a finalized generator that is not directly '\
                    'the expected generator' do
                        execute { plan.remove_task(task) }
                        refute create_matcher('bla') === task.start_event
                    end
                    it 'returns false if the task matcher returns false' do
                        task_matcher.should_receive(:===).with(task).and_return(false)
                        refute create_matcher === generator
                    end
                    it 'returns true if the task matcher returns true '\
                       'and the symbol match is default' do
                        task_matcher.should_receive(:===).with(task).and_return(true)
                        assert create_matcher === generator
                    end
                    it 'returns false if the task matcher returns true '\
                       'but the symbol does not match' do
                        task_matcher.should_receive(:===).with(task).and_return(true)
                        refute create_matcher('bla') === generator
                    end
                    it 'returns true if the task matcher returns true and '\
                       'the symbol matches' do
                        task_matcher.should_receive(:===).with(task).and_return(true)
                        symbol_match = flexmock
                        symbol_match.should_receive(:===).with('stop').and_return(true)
                        assert create_matcher(symbol_match) === generator
                    end
                    it 'returns false if it is forwarded to another task for which '\
                    'the task matcher returns false' do
                        task_matcher.should_receive(:===).with(task).and_return(false)
                        refute create_matcher === source_generator
                    end
                    it 'returns true if it is forwarded to another task for which '\
                    'the task matcher returns true and the symbol match is default' do
                        task_matcher.should_receive(:===).with(task).and_return(true)
                        assert create_matcher === source_generator
                    end
                    it 'returns false if it is forwarded to another task for which '\
                    'the task matcher returns true but the symbol does not match' do
                        task_matcher.should_receive(:===).with(task).and_return(true)
                        refute create_matcher('bla') === source_generator
                    end
                    it 'returns true if it is forwarded to another task for which '\
                    'the task matcher returns true and the symbol matches' do
                        task_matcher.should_receive(:===).with(task).and_return(true)
                        @symbol_match = flexmock
                        symbol_match.should_receive(:===).with('failed').and_return(false)
                        symbol_match.should_receive(:===).with('failed').and_return(false)
                        symbol_match.should_receive(:===).with('stop').and_return(true)
                        assert create_matcher(symbol_match) === source_generator
                    end
                end
            end
        end
    end
end
