# frozen_string_literal: true

class Object
    def dot_id
        id = object_id
        id = if id < 0
                 (0xFFFFFFFFFFFFFFFF + id).to_s
             else
                 id.to_s
             end
        "object_#{id}"
    end
end
