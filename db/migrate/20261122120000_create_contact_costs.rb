# frozen_string_literal: true

# Costs sent to a customer: one row per product, packaging and date, as the
# sales team used to keep them in a spreadsheet per customer.
class CreateContactCosts < ActiveRecord::Migration[7.1]
  def change
    create_table :contact_costs, id: :uuid do |t|
      t.references :contact, type: :uuid, null: false, foreign_key: { on_delete: :cascade }, index: false
      t.references :user, type: :uuid, null: true, index: true
      t.date :sent_on, null: false
      t.string :product_code, null: false, limit: 80
      t.string :color, limit: 120
      t.decimal :package_size, precision: 12, scale: 3, null: false
      t.string :unit, null: false, default: 'kg', limit: 8
      t.decimal :unit_price, precision: 14, scale: 4, null: false
      t.string :currency, null: false, default: 'BRL', limit: 3
      t.string :recipient, limit: 120
      t.text :notes
      t.timestamps
    end
    add_index :contact_costs, [:contact_id, :sent_on]
  end
end
