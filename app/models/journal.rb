#-- encoding: UTF-8
#-- copyright
# ChiliProject is a project management system.
#
# Copyright (C) 2010-2011 the ChiliProject Team
#
# This program is free software; you can redistribute it and/or
# modify it under the terms of the GNU General Public License
# as published by the Free Software Foundation; either version 2
# of the License, or (at your option) any later version.
#
# See doc/COPYRIGHT.rdoc for more details.
#++

require_dependency 'journal_formatter'

# The ActiveRecord model representing journals.
class Journal < ActiveRecord::Base
  unloadable

  include Comparable
  include JournalFormatter
  include JournalDeprecated

  # Make sure each journaled model instance only has unique version ids
  validates_uniqueness_of :version, :scope => [:journaled_id, :type]

  # Define a default class_name to prevent `uninitialized constant Journal::Journaled`
  # subclasses will be given an actual class name when they are created by aaj
  #
  #  e.g. IssueJournal will get :class_name => 'Issue'
  belongs_to :journaled, :class_name => 'Journal'
  belongs_to :user

  #attr_protected :user_id

  # "touch" the journaled object on creation
  after_create :touch_journaled_after_creation

  # ActiveRecord::Base#changes is an existing method, so before serializing the +changes+ column,
  # the existing +changes+ method is undefined. The overridden +changes+ method pertained to
  # dirty attributes, but will not affect the partial updates functionality as that's based on
  # an underlying +changed_attributes+ method, not +changes+ itself.
  # undef_method :changes
  serialize :changes, Hash

  # Scopes to all journals excluding the initial journal - useful for change
  # logs like the history on issue#show
  named_scope "changing", :conditions => ["version > 1"]


  raise "This code relies on ActiveRecord 2.3.x internals. ActiveRecord 3.x's
         touch should already not trigger the callbacks, as far as I can tell.
         So then it should be save to change the following method back to
         journaled.touch" if Rails.version >= '3'

  def touch_journaled_after_creation
    current_time = created_at

    # strip micro seconds since they will not be stored in db anyway
    current_time = current_time - (current_time.usec / 1_000_000.00)

    attributes = journaled.class.column_names.select { |c| ['updated_at', 'updated_on'].include? c }
    changes = {}

    # write new timestamp to journaled model without marking it as dirty
    attributes.each do |attribute|
      next if current_time == journaled[attribute]

      changes[attribute] = journaled.write_attribute_without_dirty(attribute, current_time)
    end

    return if changes.empty?

    # saving without triggering callbacks
    primary_key = journaled.class.primary_key
    journaled.class.update_all(changes, {primary_key => journaled[primary_key]})
  end

  # In conjunction with the included Comparable module, allows comparison of journal records
  # based on their corresponding version numbers, creation timestamps and IDs.
  def <=>(other)
    [version, created_at, id].map(&:to_i) <=> [other.version, other.created_at, other.id].map(&:to_i)
  end

  # Returns whether the version has a version number of 1. Useful when deciding whether to ignore
  # the version during reversion, as initial versions have no serialized changes attached. Helps
  # maintain backwards compatibility.
  def initial?
    version < 2
  end

  # The anchor number for html output
  def anchor
    version - 1
  end

  # Possible shortcut to the associated project
  def project
    if journaled.respond_to?(:project)
      journaled.project
    elsif journaled.is_a? Project
      journaled
    else
      nil
    end
  end

  def editable_by?(user)
    journaled.journal_editable_by?(user)
  end

  def details
    attributes["changes"] || {}
  end

  alias_method :changes, :details

  def new_value_for(prop)
    details[prop.to_s].last if details.keys.include? prop.to_s
  end

  def old_value_for(prop)
    details[prop.to_s].first if details.keys.include? prop.to_s
  end

  # Returns a string of css classes
  def css_classes
    s = 'journal'
    s << ' has-notes' unless notes.blank?
    s << ' has-details' unless details.empty?
    s
  end

  # This is here to allow people to disregard the difference between working with a
  # Journal and the object it is attached to.
  # The lookup is as follows:
  ## => Call super if the method corresponds to one of our attributes (will end up in AR::Base)
  ## => Try the journaled object with the same method and arguments
  ## => On error, call super
  def method_missing(method, *args, &block)
    return super if respond_to?(method) || attributes[method.to_s]
    journaled.send(method, *args, &block)
  rescue NoMethodError => e
    e.name == method ? super : raise(e)
  end

end
