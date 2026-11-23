# frozen_string_literal: true

# == Schema Information
#
# Table name: contact_costs
#
#  id           :uuid             not null, primary key
#  color        :string(120)
#  currency     :string(3)        default("BRL"), not null
#  notes        :text
#  package_size :decimal(12, 3)   not null
#  product_code :string(80)       not null
#  recipient    :string(120)
#  sent_on      :date             not null
#  unit         :string(8)        default("kg"), not null
#  unit_price   :decimal(14, 4)   not null
#  created_at   :datetime         not null
#  updated_at   :datetime         not null
#  contact_id   :uuid             not null
#  user_id      :uuid
#
# Indexes
#
#  index_contact_costs_on_contact_id_and_sent_on  (contact_id,sent_on)
#  index_contact_costs_on_user_id                 (user_id)
#
# A price sent to a customer: product, packaging (size and unit), price per
# unit and currency, on a date. `user` is the salesperson who logged it and
# `recipient` the person at the customer who received it.
class ContactCost < ApplicationRecord
  UNITS = %w[kg g L mL un].freeze

  belongs_to :contact
  belongs_to :user, optional: true

  before_validation :normalize

  validates :sent_on, presence: true
  validates :product_code, presence: true, length: { maximum: 80 }
  validates :color, :recipient, length: { maximum: 120 }
  validates :package_size, presence: true, numericality: { greater_than: 0 }
  validates :unit_price, presence: true, numericality: { greater_than: 0 }
  validates :unit, inclusion: { in: UNITS }
  validates :currency, inclusion: { in: Product::ALLOWED_CURRENCIES }

  scope :latest, -> { order(sent_on: :desc, product_code: :asc, package_size: :asc, created_at: :desc) }

  private

  def normalize
    self.product_code = product_code&.squish&.upcase
    self.color = color&.squish.presence
    self.recipient = recipient&.squish.presence
    self.notes = notes&.strip.presence
    self.currency = currency&.upcase
  end
end
