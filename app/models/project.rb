class Project < ApplicationRecord
  has_many :kanban_cards, dependent: :nullify

  validates :name, presence: true, uniqueness: true
  validates :slug, presence: true, uniqueness: true

  scope :ordered, -> { order(:name) }
end
