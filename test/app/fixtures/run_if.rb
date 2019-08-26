require 'roby/test/dsl'

describe 'selects tests to run based on the mode' do
    extend Roby::Test::DSL

    it 'runs this in all modes' do
        puts "\nTEST: all"
    end

    run_on_robot 'special_robot' do
        it 'runs this in the special_robot robot' do
            puts "\nTEST: special_robot"
        end
    end

    run_simulated do
        it 'runs this not in live mode' do
            puts "\nTEST: simulated"
        end
    end

    run_live do
        it 'runs this in live mode' do
            puts "\nTEST: live"
        end
    end
end