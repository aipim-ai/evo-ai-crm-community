# == Schema Information
#
# Table name: notes
#
#  id          :uuid             not null, primary key
#  content     :text             not null
#  kind        :integer          default("note"), not null
#  occurred_at :datetime         not null
#  created_at  :datetime         not null
#  updated_at  :datetime         not null
#  contact_id  :uuid             not null
#  user_id     :uuid
#
# Indexes
#
#  index_notes_on_contact_id                  (contact_id)
#  index_notes_on_contact_id_and_occurred_at  (contact_id,occurred_at)
#  index_notes_on_user_id                     (user_id)
#
class Note < ApplicationRecord
  # What the entry records in the contact history. `note` is an internal remark;
  # the other kinds are touches with the contact and count as "last contact".
  # Explicit attribute keeps the model bootable before the column is migrated
  # (EVO-1999 deploy scenario); type/default match 20261023120000.
  attribute :kind, :integer, default: 0
  enum :kind, { note: 0, call: 1, message: 2, meeting: 3, email: 4 }, prefix: true, validate: true

  validates :content, presence: true
  validates :contact_id, presence: true

  belongs_to :contact
  belongs_to :user, optional: true

  before_validation { self.occurred_at ||= Time.current }

  scope :latest, -> { order(occurred_at: :desc, created_at: :desc) }
  scope :touches, -> { where.not(kind: :note) }
end
