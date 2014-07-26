module Billing
  class Charge < ActiveRecord::Base
    include AccountItem
    belongs_to :account, inverse_of: :charges, validate: true
    belongs_to :chargable, polymorphic: true
    belongs_to :origin, inverse_of: :charges
    has_one :modifier, inverse_of: :charge

    monetize :price_cents
    monetize :value_cents
    
    delegate :paid?, to: :account
    
    scope :unpaid, -> { joins(:account).where.not(billing_accounts: { balance_cents: 0}) }
    scope :paid, -> { joins(:account).where(billing_accounts: { balance_cents: 0}) }
    scope :in_period, lambda {|from, to| where(revenue_at: from..to) }
    
    validates_presence_of :price
    validates_numericality_of :value, greater_than_or_equal_to: 0
    
    before_validation do
      self.value = price unless modifier.present?
    end
    
    class << self
      def args(*args)
        case when args.blank? || args.first.is_a?(Hash) then
          {}.merge(*args)
        else
          h = { price: args.shift.to_money }
          args.any? ? h.merge(*args) : h
        end
      end
    end
  end
end
