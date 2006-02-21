module Roby
    class ExtendableStruct
        def initialize(attach_to = nil, attach_name = nil)
            @members = Hash.new
            @attach = if attach_to
                          lambda { attach_to.send("#{attach_name}=", self) } 
                      end
            @stable = false
        end
        def attach
            return unless @attach
            @attach.call
            @attach = nil
        end
        
        def respond_to?(name)
            return true if super
            name = name.to_s
            if name[-1] == ?=
                @members.has_key?(name[0..-2])
            else
                @members.has_key?(name) 
            end
        end
        def method_missing(name, *args, &update)
            attach
            name = name.to_s
            if name[-1] == ?= # Setter
                if stable?
                    raise NoMethodError, "cannot use #{name} while #{self} is stable"
                else
                    return @members[name[0..-2]] = args.first
                end
            elsif args.empty?
                member = @members[name]
                member ||= ExtendableStruct.new(self, name) unless stable?
                super unless member

                if update
                    return member.update(&update)
                elsif !update
                    return member
                end
            end

            super
        end

        def update(hash = nil)
            attach
            hash.each { |k, v| send("#{k}=", v) } if hash
            yield(self) if block_given?
            self
        end

        def stable?; @stable end
        def stable!(recursive = false)
            @stable = true
            if recursive
                @members.each { |name, object| object.stable!(recursive) if object.respond_to?(:stable!) }
            end
        end
    end

    State = ExtendableStruct.new
end

