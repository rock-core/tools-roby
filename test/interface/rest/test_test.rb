# frozen_string_literal: true

require 'roby/test/self'
require 'roby/test/spec'
require 'roby/interface/rest/test'
require 'roby/interface/rest/task'

module Roby
    module Interface
        module REST
            class RESTTestHelperTest < Roby::Test::Spec
                include Test

                def rest_api
                    Class.new(Grape::API) do
                        format :json

                        mount API
                        helpers Helpers

                        get '/test' do
                            execute { roby_plan.num_tasks }
                        end
                    end
                end

                it 'allows to execute a test that synchronizes with the engine' do
                    assert_equal 0, JSON.parse(get('/test').body)
                end
            end
        end
    end
end
