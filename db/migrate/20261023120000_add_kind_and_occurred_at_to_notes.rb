# frozen_string_literal: true

# Turns contact notes into history entries: `kind` says what happened (a call,
# a meeting, ...) and `occurred_at` says when, which is not always when it was
# typed in. Existing rows stay plain notes dated at their creation.
class AddKindAndOccurredAtToNotes < ActiveRecord::Migration[7.1]
  def up
    add_column :notes, :kind, :integer, default: 0, null: false
    add_column :notes, :occurred_at, :datetime
    execute 'UPDATE notes SET occurred_at = created_at WHERE occurred_at IS NULL'
    change_column_null :notes, :occurred_at, false
    add_index :notes, [:contact_id, :occurred_at]
  end

  def down
    remove_index :notes, [:contact_id, :occurred_at]
    remove_column :notes, :occurred_at
    remove_column :notes, :kind
  end
end
