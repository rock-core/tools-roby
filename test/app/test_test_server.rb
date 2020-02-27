# frozen_string_literal: true

require 'roby/test/self'
require 'roby/app/test_server'

module Roby
    module App
        describe TestServer do
            it 'marshals an UnexpectedError\'s original error using droby' do
                error = flexmock
                error.should_receive(:droby_dump)
                     .with(peer = flexmock)
                     .and_return(droby_dumped = flexmock)
                e = Minitest::UnexpectedError.new(error)
                e_droby = e.droby_dump(peer)
                assert_equal droby_dumped, e_droby.error
            end

            it 'unmarshals an UnexpectedError\'s original error using droby' do
                manager = flexmock
                manager.should_receive(:local_object)
                       .with(error = flexmock)
                       .and_return(unmarshalled = flexmock)
                e = Minitest::UnexpectedError.new(error)
                e_unmarshalled = e.proxy(manager)
                assert_equal unmarshalled, e_unmarshalled.error
            end
        end
    end
end
