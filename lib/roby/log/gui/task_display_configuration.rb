module Roby
    module LogReplay
	module TaskDisplayConfiguration
            # A set of prefixes that should be removed from the task names
	    attribute(:removed_prefixes) { Set.new }

            # Any task whose label matches one regular expression in this set is
            # not displayed
            attribute(:hidden_labels) { Array.new }

	    # Compute the prefixes to remove from in filter_prefixes:
	    # enable only the ones that are flagged, and sort them by
	    # prefix length
	    def update_prefixes_removal
		@prefixes_removal = removed_prefixes.to_a.
                    sort_by { |p| p.length }.
		    reverse
	    end

            def filtered_out_label?(label)
                (!hidden_labels.empty? && hidden_labels.any? { |match| label.include?(match) })
            end

	    def filter_prefixes(string)
		# @prefixes_removal is computed in RelationsCanvas#update
		for prefix in @prefixes_removal
		    string = string.gsub(prefix, '')
		end
                if string =~ /^::/
                    string = string[2..-1]
                end
		string
	    end

	    # If true, show the ownership in the task descriptions
	    attribute(:show_ownership) { true }
	    # If true, show the arguments in the task descriptions
	    attribute(:show_arguments) { false }
	end
    end
end

