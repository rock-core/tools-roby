$LOAD_PATH.unshift File.expand_path(File.join('..', '..', 'lib'), File.dirname(__FILE__))
require 'roby/test/common'
require 'roby/tasks/simple'

describe Roby::Coordination::Script do
    include Roby::SelfTest

    attr_reader :script

    before do
        script_m = Class.new do
            include Roby::Coordination::Script
            attr_reader :root_task

            attr_reader :instructions

            def initialize(plan)
                @instructions = Array.new
                plan.add(@root_task = Roby::Tasks::Simple.new)
            end
        end
        @script = script_m.new(plan)
    end

    describe "#step" do
        it "passes to the next instruction if #execute returns true" do
            ins1 = flexmock(:disabled? => false)
            ins2 = flexmock(:disabled? => false)
            ins1.should_receive(:execute).once.and_return(true)
            ins2.should_receive(:execute).once.and_return(false)
            script.instructions << ins1 << ins2
            script.step
            assert_equal script.current_instruction, ins2
        end

        it "passes to the next instruction if the current one is disabled" do
            ins1 = flexmock(:disabled? => true)
            ins2 = flexmock(:disabled? => false)
            ins1.should_receive(:execute).never
            ins2.should_receive(:execute).once.and_return(false)
            script.instructions << ins1 << ins2
            script.step
            assert_equal script.current_instruction, ins2
        end

        it "ends when there are no instructions left to execute" do
            ins1 = flexmock(:disabled? => true)
            script.instructions << ins1
            script.step
            assert !script.current_instruction
        end

        it "sticks with the current instruction until it is disabled if #execute returns false" do
            ins = flexmock(:disabled? => false)
            ins.should_receive(:execute).once.and_return(false)
            script.instructions << ins
            script.step
            script.step
            assert_equal ins, script.current_instruction
        end
    end

    describe "#finished?" do
        it "returns true on an empty script" do
            assert script.finished?
        end
        it "returns true if all instructions have been processed" do
            ins1 = flexmock(:disabled? => true)
            script.instructions << ins1
            script.step
            assert script.finished?
        end
        it "returns false if the last instruction needs to be called back" do
            ins = flexmock(:disabled? => false, :execute => false)
            script.instructions << ins
            script.step
            assert !script.finished?
        end
    end
end

