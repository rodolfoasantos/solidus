# coding: UTF-8

require 'spec_helper'

module ThirdParty
  class Extension < Spree::Base
    # nasty hack so we don't have to create a table to back this fake model
    self.table_name = 'spree_products'
  end
end

describe Spree::Product, type: :model do
  context 'product instance' do
    let(:product) { create(:product) }
    let(:variant) { create(:variant, product: product) }

    context '#duplicate' do
      before do
        allow(product).to receive_messages taxons: [create(:taxon)]
      end

      it 'duplicates product' do
        clone = product.duplicate
        expect(clone.name).to eq('COPY OF ' + product.name)
        expect(clone.master.sku).to eq('COPY OF ' + product.master.sku)
        expect(clone.taxons).to eq(product.taxons)
        expect(clone.images.size).to eq(product.images.size)
      end

      it 'calls #duplicate_extra' do
        expect_any_instance_of(Spree::Product).to receive(:duplicate_extra) do |product, old_product|
          product.name = old_product.name.reverse
        end

        clone = product.duplicate
        expect(clone.name).to eq(product.name.reverse)
      end
    end

    describe "#save" do
      before { product.update_columns(updated_at: 1.day.ago) }
      subject { product.save! }

      shared_examples "a change occurred" do
        it "should change updated_at" do
          expect { subject }.to change{ product.updated_at }
        end

        it "should touch taxons" do
          taxon = create(:taxon, products: [product])
          taxon.update_columns(updated_at: 1.day.ago)
          product.taxons.reload
          expect { subject }.to change{ taxon.reload.updated_at }
        end
      end

      shared_examples "no change occurred" do
        it "should not change updated_at" do
          expect { subject }.not_to change{ product.updated_at }
        end

        it "should not touch taxons" do
          taxon = create(:taxon, products: [product])
          taxon.update_columns(updated_at: 1.day.ago)
          product.taxons.reload
          expect { subject }.not_to change{ taxon.reload.updated_at }
        end
      end

      context "when nothing has changed" do
        it_behaves_like "no change occurred"
      end

      context "when the product itself was changed" do
        before do
          product.name = "Perri-air"
        end

        it_behaves_like "a change occurred"
      end

      context "when master variant changed" do
        before do
          product.master.sku = "Something changed"
        end

        it_behaves_like "a change occurred"

        it "saves the master" do
          product.save!
          expect(product.reload.master.sku).to eq "Something changed"
        end
      end

      context "when master default price changed" do
        before do
          master = product.master
          master.default_price.price = 11
          master.save!
          product.master.default_price.price = 12
        end

        it_behaves_like "a change occurred"

        it "saves the default_price" do
          product.save!
          expect(product.reload.master.default_price.price).to eq 12
        end
      end
    end

    context "product has no variants" do
      context "#destroy" do
        it "should set deleted_at value" do
          product.destroy
          expect(product.deleted_at).not_to be_nil
          expect(product.master.reload.deleted_at).not_to be_nil
        end
      end
    end

    context "product has variants" do
      before do
        create(:variant, product: product)
      end

      context "#destroy" do
        it "should set deleted_at value" do
          product.destroy
          expect(product.deleted_at).not_to be_nil
          expect(product.variants_including_master.all? { |v| !v.deleted_at.nil? }).to be true
        end
      end
    end

    context "#price" do
      # Regression test for https://github.com/spree/spree/issues/1173
      it 'strips non-price characters' do
        product.price = "$10"
        expect(product.price).to eq(10.0)
      end
    end

    context "#display_price" do
      before { product.price = 10.55 }

      it "shows the amount" do
        expect(product.display_price.to_s).to eq("$10.55")
      end

      context "with currency set to JPY" do
        before do
          product.master.default_price.currency = 'JPY'
          product.master.default_price.save!
          Spree::Config[:currency] = 'JPY'
        end

        it "displays the currency in yen" do
          expect(product.display_price.to_s).to eq("¥11")
        end
      end
    end

    context "#available?" do
      it "should be available if date is in the past" do
        product.available_on = 1.day.ago
        expect(product).to be_available
      end

      it "should not be available if date is nil or in the future" do
        product.available_on = nil
        expect(product).not_to be_available

        product.available_on = 1.day.from_now
        expect(product).not_to be_available
      end

      it "should not be available if destroyed" do
        product.destroy
        expect(product).not_to be_available
      end
    end

    context "variants_and_option_values" do
      let!(:high) { create(:variant, product: product) }
      let!(:low) { create(:variant, product: product) }

      before { high.option_values.destroy_all }

      it "returns only variants with option values" do
        expect(product.variants_and_option_values).to eq([low])
      end
    end

    describe "#variant_option_values_by_option_type" do
      let(:size) { create(:option_type, name: 'size') }
      let(:length) { create(:option_type, name: 'length') }
      let(:product) { create(:product, option_types: [size, length]) }
      let(:size_small) { create(:option_value, name: 'small', option_type: size, position: 3) }
      let(:size_medium) { create(:option_value, name: 'medium', option_type: size, position: 1) }
      let(:size_large) { create(:option_value, name: 'large', option_type: size, position: 2) }
      let!(:variant) { create(:variant, product: product, option_values: [size_small, size_medium]) }

      subject { product.variant_option_values_by_option_type }

      it "returns the option values associated with the product's variants grouped by option type" do
        expect(subject).to eq({ size => [size_medium, size_small] })
      end
    end

    describe "#find_variant_property_rule" do
      let(:option_value) { create(:option_value) }

      subject { product.find_variant_property_rule([option_value.id]) }

      context "a matching rule exists" do
        let!(:rule) do
          create(:variant_property_rule, product: product, option_value: option_value)
        end

        it "returns the rule" do
          expect(subject).to eq rule
        end
      end

      context "a matching rule doesn't exist" do
        it "returns nil" do
          expect(subject).to be_nil
        end
      end
    end

    describe 'Variants sorting' do
      let(:master){ product.master }

      let!(:second) { create(:variant, product: product) }
      let!(:third)  { create(:variant, product: product) }
      let!(:first)  { create(:variant, product: product) }

      before do
        first.update_columns(position: 2)
        second.update_columns(position: 3)
        third.update_columns(position: 4)
      end

      context 'without master variant' do
        it 'sorts variants by position' do
          expect(product.variants).to eq([first, second, third])
        end
      end

      context 'with master variant' do
        it 'sorts variants by position' do
          expect(product.variants_including_master).to eq([master, first, second, third])
        end
      end
    end

    context "has stock movements" do
      let(:product) { create(:product) }
      let(:variant) { product.master }
      let(:stock_item) { variant.stock_items.first }

      it "doesnt raise ReadOnlyRecord error" do
        Spree::StockMovement.create!(stock_item: stock_item, quantity: 1)
        product.destroy
      end
    end

    # Regression test for https://github.com/spree/spree/issues/3737
    context "has stock items" do
      let(:product) { create(:product) }
      it "can retrieve stock items" do
        expect(product.master.stock_items.first).not_to be_nil
        expect(product.stock_items.first).not_to be_nil
      end
    end

    context "slugs" do
      it "normalizes slug on update validation" do
        product.slug = "hey//joe"
        product.valid?
        expect(product.slug).not_to match "/"
      end

      it "renames slug on destroy" do
        old_slug = product.slug
        product.destroy
        expect(old_slug).to_not eq product.slug
      end

      it "validates slug uniqueness" do
        existing_product = product
        new_product = create(:product)
        new_product.slug = existing_product.slug

        expect(new_product.valid?).to eq false
      end

      it "falls back to 'name-sku' for slug if regular name-based slug already in use" do
        product1 = build(:product)
        product1.name = "test"
        product1.sku = "123"
        product1.save!

        product2 = build(:product)
        product2.name = "test"
        product2.sku = "456"
        product2.save!

        expect(product2.slug).to eq 'test-456'
      end
    end

    context "associations" do
      describe "product_option_types" do
        it "touches the product instance when an option type is added" do
          expect {
            product.product_option_types.create(option_type: create(:option_type, name: 'new-option-type'))
            product.reload
          }.to change { product.updated_at }
        end

        it "touches product instance when an option type is removed" do
          product.product_option_types.create(option_type: create(:option_type, name: 'new-option-type'))
          expect {
            product.product_option_types = []
            product.reload
          }.to change { product.updated_at }
        end
      end
    end

    context "#really_destroy!" do
      it "destroy the product" do
        product.really_destroy!
        expect(product).not_to be_persisted
      end
    end
  end

  context "properties" do
    let(:product) { create(:product) }

    it "should properly assign properties" do
      product.set_property('the_prop', 'value1')
      expect(product.property('the_prop')).to eq('value1')

      product.set_property('the_prop', 'value2')
      expect(product.property('the_prop')).to eq('value2')
    end

    it "should not create duplicate properties when set_property is called" do
      expect {
        product.set_property('the_prop', 'value2')
        product.save
        product.reload
      }.not_to change(product.properties, :length)

      expect {
        product.set_property('the_prop_new', 'value')
        product.save
        product.reload
        expect(product.property('the_prop_new')).to eq('value')
      }.to change { product.properties.length }.by(1)
    end

    # Regression test for https://github.com/spree/spree/issues/2455
    it "should not overwrite properties' presentation names" do
      Spree::Property.where(name: 'foo').first_or_create!(presentation: "Foo's Presentation Name")
      product.set_property('foo', 'value1')
      product.set_property('bar', 'value2')
      expect(Spree::Property.where(name: 'foo').first.presentation).to eq("Foo's Presentation Name")
      expect(Spree::Property.where(name: 'bar').first.presentation).to eq("bar")
    end

    # Regression test for https://github.com/spree/spree/issues/4416
    context "#possible_promotions" do
      let!(:promotion) do
        create(:promotion, advertise: true, starts_at: 1.day.ago)
      end
      let!(:rule) do
        Spree::Promotion::Rules::Product.create(
          promotion: promotion,
          products: [product]
        )
      end

      it "lists the promotion as a possible promotion" do
        expect(product.possible_promotions).to include(promotion)
      end
    end
  end

  context '#create' do
    let!(:prototype) { create(:prototype) }
    let!(:product) { Spree::Product.new(name: "Foo", price: 1.99, shipping_category_id: create(:shipping_category).id) }

    before { product.prototype_id = prototype.id }

    context "when prototype is supplied" do
      it "should create properties based on the prototype" do
        product.save
        expect(product.properties.count).to eq(1)
      end
    end

    context "when prototype with option types is supplied" do
      def build_option_type_with_values(name, values)
        ot = create(:option_type, name: name)
        values.each do |val|
          ot.option_values.create(name: val.downcase, presentation: val)
        end
        ot
      end

      let(:prototype) do
        size = build_option_type_with_values("size", %w(Small Medium Large))
        create(:prototype, name: "Size", option_types: [size])
      end

      let(:option_values_hash) do
        hash = {}
        prototype.option_types.each do |i|
          hash[i.id.to_s] = i.option_value_ids
        end
        hash
      end

      it "should create option types based on the prototype" do
        product.save
        expect(product.option_type_ids.length).to eq(1)
        expect(product.option_type_ids).to eq(prototype.option_type_ids)
      end

      it "should create product option types based on the prototype" do
        product.save
        expect(product.product_option_types.pluck(:option_type_id)).to eq(prototype.option_type_ids)
      end

      it "should create variants from an option values hash with one option type" do
        product.option_values_hash = option_values_hash
        product.save
        expect(product.variants.length).to eq(3)
      end

      it "should still create variants when option_values_hash is given but prototype id is nil" do
        product.option_values_hash = option_values_hash
        product.prototype_id = nil
        product.save
        expect(product.option_type_ids.length).to eq(1)
        expect(product.option_type_ids).to eq(prototype.option_type_ids)
        expect(product.variants.length).to eq(3)
      end

      it "should create variants from an option values hash with multiple option types" do
        color = build_option_type_with_values("color", %w(Red Green Blue))
        logo  = build_option_type_with_values("logo", %w(Ruby Rails Nginx))
        option_values_hash[color.id.to_s] = color.option_value_ids
        option_values_hash[logo.id.to_s] = logo.option_value_ids
        product.option_values_hash = option_values_hash
        product.save
        product.reload
        expect(product.option_type_ids.length).to eq(3)
        expect(product.variants.length).to eq(27)
      end
    end
  end

  context "#images" do
    let(:product) { create(:product) }
    let(:image) { File.open(File.expand_path('../../../fixtures/thinking-cat.jpg', __FILE__)) }
    let(:params) { { viewable_id: product.master.id, viewable_type: 'Spree::Variant', attachment: image, alt: "position 2", position: 2 } }

    before do
      Spree::Image.create(params)
      Spree::Image.create(params.merge({ alt: "position 1", position: 1 }))
      Spree::Image.create(params.merge({ viewable_type: 'ThirdParty::Extension', alt: "position 1", position: 2 }))
    end

    it "only looks for variant images" do
      expect(product.images.size).to eq(2)
    end

    it "should be sorted by position" do
      expect(product.images.pluck(:alt)).to eq(["position 1", "position 2"])
    end
  end

  # Regression tests for https://github.com/spree/spree/issues/2352
  context "classifications and taxons" do
    it "is joined through classifications" do
      reflection = Spree::Product.reflect_on_association(:taxons)
      expect(reflection.options[:through]).to eq(:classifications)
    end

    it "will delete all classifications" do
      reflection = Spree::Product.reflect_on_association(:classifications)
      expect(reflection.options[:dependent]).to eq(:delete_all)
    end
  end

  context '#total_on_hand' do
    it 'should be infinite if track_inventory_levels is false' do
      Spree::Config[:track_inventory_levels] = false
      expect(build(:product, variants_including_master: [build(:master_variant)]).total_on_hand).to eql(Float::INFINITY)
    end

    it 'should be infinite if variant is on demand' do
      Spree::Config[:track_inventory_levels] = true
      expect(build(:product, variants_including_master: [build(:on_demand_master_variant)]).total_on_hand).to eql(Float::INFINITY)
    end

    it 'should return sum of stock items count_on_hand' do
      product = create(:product)
      product.stock_items.first.set_count_on_hand 5
      product.variants_including_master(true) # force load association
      expect(product.total_on_hand).to eql(5)
    end

    it 'should return sum of stock items count_on_hand when variants_including_master is not loaded' do
      product = create(:product)
      product.stock_items.first.set_count_on_hand 5
      expect(product.reload.total_on_hand).to eql(5)
    end
  end

  # Regression spec for https://github.com/spree/spree/issues/5588
  context '#validate_master when duplicate SKUs entered' do
    let!(:first_product) { create(:product, sku: 'a-sku') }
    let(:second_product) { build(:product, sku: 'a-sku') }

    subject { second_product }
    it { is_expected.to be_invalid }
  end

  describe '.new' do
    let(:product) { Spree::Product.new(attributes) }

    shared_examples "new product with master" do
      it "initializes master correctly" do
        expect(product.master.is_master).to be true
        expect(product.master.product).to be product
      end
    end

    context 'no attributes' do
      let(:attributes) { {} }
      it_behaves_like "new product with master"
    end

    context 'initializing with variant attributes' do
      let(:attributes) { { sku: 'FOO' } }

      it_behaves_like "new product with master"

      it "initializes the variant with the correct attributes" do
        expect(product.master.sku).to eq 'FOO'
        expect(product.sku).to eq 'FOO'
      end
    end
  end
end
