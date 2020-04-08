# frozen_string_literal: true

module Roby
    module DRoby
        module V5
            # These objects are used in distributed Roby to identify objects across
            # the various Roby instances
            class DRobyID
                # The object ID
                attr_reader :id

                def initialize(id)
                    @id = id
                    @hash = id.hash
                end

                def ==(other) # :nodoc:
                    other.kind_of?(DRobyID) && other.id == id
                end

                alias eql? ==
                attr_reader :hash

                def to_s
                    "#<DRobyID:#{id}>"
                end

                def inspect
                    to_s
                end

                def pretty_print(pp)
                    pp.text to_s
                end

                class << self
                    attr_reader :droby_id_allocator
                end
                @droby_id_allocator = Concurrent::AtomicFixnum.new

                def self.allocate
                    DRobyID.new(droby_id_allocator.increment)
                end
            end
        end
    end
end
