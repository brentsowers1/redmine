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

require 'redmine/scm/adapters/mercurial_adapter'

class Repository::Mercurial < Repository
  # sort changesets by revision number
  has_many :changesets, :order => "#{Changeset.table_name}.id DESC", :foreign_key => 'repository_id'

  attr_protected :root_url
  validates_presence_of :url

  FETCH_AT_ONCE = 100  # number of changesets to fetch at once

  def scm_adapter
    Redmine::Scm::Adapters::MercurialAdapter
  end
  
  def self.scm_name
    'Mercurial'
  end

  # Returns the identifier for the given mercurial changeset
  def self.changeset_identifier(changeset)
    changeset.scmid
  end

  # Returns the readable identifier for the given mercurial changeset
  def self.format_changeset_identifier(changeset)
    "#{changeset.revision}:#{changeset.scmid}"
  end
  
  def entries(path=nil, identifier=nil)
    entries=scm.entries(path, identifier)
    if entries
      entries.each do |entry|
        next unless entry.is_file?
        # Set the filesize unless browsing a specific revision
        if identifier.nil?
          full_path = File.join(root_url, entry.path)
          entry.size = File.stat(full_path).size if File.file?(full_path)
        end
        # Search the DB for the entry's last change
        change = changes.find(:first, :conditions => ["path = ?", scm.with_leading_slash(entry.path)], :order => "#{Changeset.table_name}.committed_on DESC")
        if change
          entry.lastrev.identifier = change.changeset.revision
          entry.lastrev.name = change.changeset.revision
          entry.lastrev.author = change.changeset.committer
          entry.lastrev.revision = change.revision
        end
      end
    end
    entries
  end

  # Finds and returns a revision with a number or the beginning of a hash
  def find_changeset_by_name(name)
    if /[^\d]/ =~ name or name.to_s.size > 8
      e = changesets.find(:first, :conditions => ['scmid = ?', name.to_s])
    else
      e = changesets.find(:first, :conditions => ['revision = ?', name.to_s])
    end
    return e if e
    changesets.find(:first, :conditions => ['scmid LIKE ?', "#{name}%"])  # last ditch
  end

  # Returns the latest changesets for +path+; sorted by revision number
  def latest_changesets(path, rev, limit=10)
    if path.blank?
      changesets.find(:all, :include => :user, :limit => limit)
    else
      changes.find(:all, :include => {:changeset => :user},
                         :conditions => ["path = ?", path.with_leading_slash],
                         :order => "#{Changeset.table_name}.id DESC",
                         :limit => limit).collect(&:changeset)
    end
  end

  def fetch_changesets
    scm_rev = scm.info.lastrev.revision.to_i
    db_rev = latest_changeset ? latest_changeset.revision.to_i : -1
    return unless db_rev < scm_rev  # already up-to-date

    logger.debug "Fetching changesets for repository #{url}" if logger
    (db_rev + 1).step(scm_rev, FETCH_AT_ONCE) do |i|
      transaction do
        scm.each_revision('', i, [i + FETCH_AT_ONCE - 1, scm_rev].min) do |re|
          cs = Changeset.create(:repository => self,
                                :revision => re.revision,
                                :scmid => re.scmid,
                                :committer => re.author,
                                :committed_on => re.time,
                                :comments => re.message)
          re.paths.each { |e| cs.create_change(e) }
        end
      end
    end
    self
  end
end
