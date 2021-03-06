# redMine - project management software
# Copyright (C) 2006-2007  Jean-Philippe Lang
#
# This program is free software; you can redistribute it and/or
# modify it under the terms of the GNU General Public License
# as published by the Free Software Foundation; either version 2
# of the License, or (at your option) any later version.
# 
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
# 
# You should have received a copy of the GNU General Public License
# along with this program; if not, write to the Free Software
# Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA  02110-1301, USA.

require 'redmine/scm/adapters/abstract_adapter'

module Redmine
  module Scm
    module Adapters    
      class BazaarAdapter < AbstractAdapter

        class Revision < Redmine::Scm::Adapters::Revision
          # Returns the readable identifier
          def format_identifier
            revision
          end
        end
      
        # Bazaar executable name
        BZR_BIN = "bzr"
        
        # Get info about the repository
        def info
          cmd = "#{BZR_BIN} revno #{target('')}"
          info = nil
          shellout(cmd) do |io|
            if io.read =~ %r{^(\d+(\.\d+)*)\r?$}
              info = Info.new({:root_url => url,
                               :lastrev => Revision.new({
                                 :identifier => $1,
                                 :revision => $1
                               })
                             })
            end
          end
          return nil if $? && $?.exitstatus != 0
          info
        rescue CommandFailed
          return nil
        end
        
        # Returns an Entries collection
        # or nil if the given path doesn't exist in the repository
        def entries(path=nil, identifier=nil)
          path ||= ''
          entries = Entries.new
          cmd = "#{BZR_BIN} ls -v --show-ids"
          rev_spec = identifier ? "revid:#{identifier}" : "-1"
          cmd << " -r #{rev_spec}"
          cmd << " #{target(path)}"
          shellout(cmd) do |io|
            prefix = "#{url}/#{path}".gsub('\\', '/')
            logger.debug "PREFIX: #{prefix}"
            re = %r{^V\s+(#{Regexp.escape(prefix)})?(\/?)([^\/]+)(\/?)\s+(\S+)\r?$}
            io.each_line do |line|
              next unless line =~ re
              entries << Entry.new({:name => $3.strip,
                                    :path => ((path.empty? ? "" : "#{path}/") + $3.strip),
                                    :kind => ($4.blank? ? 'file' : 'dir'),
                                    :size => nil,
                                    :lastrev => Revision.new(:revision => $5.strip)
                                  })
            end
          end
          return nil if $? && $?.exitstatus != 0
          logger.debug("Found #{entries.size} entries in the repository for #{target(path)}") if logger && logger.debug?
          entries.sort_by_name
        end
    
        def revisions(path=nil, identifier_from=nil, identifier_to=nil, options={})
          path ||= ''
          revisions = Revisions.new
          cmd = "#{BZR_BIN} log -n 0 -v --show-ids"
          if options[:since]
            cmd << " -r date:#{options[:since].strftime("%Y-%m-%d,%H:%M:%S")}.."
          else
            from = identifier_from ? "revid:#{identifier_from}" : "last:1"
            to = identifier_to ? "revid:#{identifier_to}" : "1"
            cmd << " -r #{to}..#{from}"
          end
          cmd << " -l #{options[:limit]} " if options[:limit]
          cmd << " #{target(path)}"
          shellout(cmd) do |io|
            revision = nil
            parsing = nil
            io.each_line do |line|
              if line =~ /^\s*----/
                revisions << revision if revision
                revision = Revision.new(:paths => [], :message => '')
                parsing = nil
              else
                next unless revision
                
                if line =~ /^\s*revno: (\d+(\.\d+)*)($|\s\[merge\]$)/
                  revision.revision = $1
                elsif line =~ /^\s*committer: (.+)$/
                  revision.author = $1.strip
                elsif line =~ /^\s*revision-id:(.+)$/
                  revision.scmid = $1.strip
                  revision.identifier = revision.revision
                elsif line =~ /^\s*timestamp: (.+)$/
                  revision.time = Time.parse($1).localtime
                elsif line =~ /^    \s*-----/
                  # partial revisions
                  parsing = nil unless parsing == 'message'
                elsif line =~ /^\s*(message|added|modified|removed|renamed):/
                  parsing = $1
                elsif line =~ /^  \s*(.*)$/
                  if parsing == 'message'
                    revision.message << "#{$1}\n"
                  else
                    if $1 =~ /^(.*)\s+(\S+)$/
                      path = $1.strip
                      revid = $2
                      case parsing
                      when 'added'
                        revision.paths << {:action => 'A', :path => "/#{path}", :revision => revid}
                      when 'modified'
                        revision.paths << {:action => 'M', :path => "/#{path}", :revision => revid}
                      when 'removed'
                        revision.paths << {:action => 'D', :path => "/#{path}", :revision => revid}
                      when 'renamed'
                        new_path = path.split('=>').last
                        revision.paths << {:action => 'M', :path => "/#{new_path.strip}", :revision => revid} if new_path
                      end
                    end
                  end
                else
                  parsing = nil
                end
              end
            end
            revisions << revision if revision
          end
          return nil if $? && $?.exitstatus != 0
          revisions
        end
        
        def diff(path, identifier_from, identifier_to=nil)
          path ||= ''
          cmd = "#{BZR_BIN} diff"
          if identifier_to.nil?
            cmd << " -c revid:#{identifier_from}"
          else
            cmd << " -r revid:#{identifier_to}..revid:#{identifier_from}"
          end
          cmd << " #{target(path)}"
          diff = []
          shellout(cmd) do |io|
            io.each_line do |line|
              diff << line
            end
          end
          #return nil if $? && $?.exitstatus != 0
          diff
        end
        
        def cat(path, identifier=nil)
          cmd = "#{BZR_BIN} cat"
          cmd << " -r revid:#{identifier}" if identifier
          cmd << " #{target(path)}"
          cat = nil
          shellout(cmd) do |io|
            io.binmode
            cat = io.read
          end
          return nil if $? && $?.exitstatus != 0
          cat
        end
        
        def annotate(path, identifier=nil)
          cmd = "#{BZR_BIN} annotate --all --show-ids"
          cmd << " -r revid:#{identifier}" if identifier
          cmd << " #{target(path)}"
          blame = Annotate.new
          # With Bazaar, there is no way to show both the regular revision
          # number (ie 121, 4.1.1, etc.) and the internal ID with one command.
          # So run through the command twice
          lines = []
          shellout(cmd) do |io|
            io.each_line do |line|
              next unless line =~ %r{^\s*(\S+?)\-(\d+)\-(.+?) \| (.*)$}
              lines << {:text => $4.rstrip, :scmid => "#{$1}-#{$2}-#{$3}", :author => $1.strip}
            end
          end
          cmd.gsub!(/ \-\-show\-ids/, "")
          i = 0
          shellout(cmd) do |io|
            io.each_line do |line|
              next unless line =~ %r{^\s*([\d\.]+) .*? \| (.*)$}
              lines[i][:revision] = $1
              i += 1
            end
          end

          lines.each do |l|
            blame.add_line(l[:text], Revision.new(:identifier => l[:scmid],
                                                  :author => l[:author], :scmid => l[:scmid],
                                                  :revision => l[:revision]))
          end
          return nil if $? && $?.exitstatus != 0
          blame
        end
      end
    end
  end
end
