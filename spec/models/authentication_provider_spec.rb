# frozen_string_literal: true

#
# Copyright (C) 2011 - present Instructure, Inc.
#
# This file is part of Canvas.
#
# Canvas is free software: you can redistribute it and/or modify it under
# the terms of the GNU Affero General Public License as published by the Free
# Software Foundation, version 3 of the License.
#
# Canvas is distributed in the hope that it will be useful, but WITHOUT ANY
# WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
# A PARTICULAR PURPOSE. See the GNU Affero General Public License for more
# details.
#
# You should have received a copy of the GNU Affero General Public License along
# with this program. If not, see <http://www.gnu.org/licenses/>.
#

describe AuthenticationProvider do
  let(:account) { Account.default }

  describe ".singleton?" do
    subject { described_class.singleton? }

    it { is_expected.to be false }
  end

  describe ".restorable?" do
    subject { described_class.restorable? }

    it { is_expected.to be false }
  end

  context "password" do
    it "decrypts the password to the original value" do
      c = AuthenticationProvider.new
      c.auth_password = "asdf"
      expect(c.auth_decrypted_password).to eql("asdf")
      c.auth_password = "2t87aot72gho8a37gh4g[awg'waegawe-,v-3o7fya23oya2o3"
      expect(c.auth_decrypted_password).to eql("2t87aot72gho8a37gh4g[awg'waegawe-,v-3o7fya23oya2o3")
    end
  end

  describe "enable_canvas_authentication" do
    before do
      account.authentication_providers.destroy_all
      account.settings[:canvas_authentication] = false
      account.save!
      account.authentication_providers.create!(auth_type: "ldap")
      account.authentication_providers.create!(auth_type: "cas")
    end

    it "leaves settings as they are after deleting one of many aacs" do
      account.authentication_providers.first.destroy
      expect(account.reload.settings[:canvas_authentication]).to be_falsey
    end

    it "enables canvas_authentication if deleting the last aac" do
      account.authentication_providers.destroy_all
      expect(account.reload.canvas_authentication?).to be true
    end
  end

  it "disables open registration when created" do
    account.settings[:open_registration] = true
    account.save!
    account.authentication_providers.create!(auth_type: "cas")
    expect(account.reload.open_registration?).to be_falsey
  end

  describe "FindByType module" do
    let!(:aac) { account.authentication_providers.create!(auth_type: "facebook") }

    it "still reloads ok" do
      expect { aac.reload }.not_to raise_error
    end

    it "works through associations that use the provided module" do
      found = account.authentication_providers.find("facebook")
      expect(found).to eq(aac)
    end
  end

  describe "#auth_provider_filter" do
    it "includes nil for legacy auth types" do
      aac = AuthenticationProvider.new(auth_type: "cas")
      expect(aac.auth_provider_filter).to eq([nil, aac])
    end

    it "is just the AAC for oauth types" do
      aac = AuthenticationProvider.new(auth_type: "facebook")
      expect(aac.auth_provider_filter).to eq(aac)
    end
  end

  describe "#duplicated_in_account?" do
    subject { authentication_provider.duplicated_in_account? }

    context "when the account lacks other auth provider with the same auth type" do
      context "and the auth provider is singleton" do
        let(:authentication_provider) { account.authentication_providers.create!(auth_type: "apple") }

        it { is_expected.to be false }
      end

      context "and the auth provider is not singleton" do
        let(:authentication_provider) { account.authentication_providers.create!(auth_type: "cas") }

        it { is_expected.to be false }
      end
    end

    context "when the account has another auth provider with the same auth type" do
      context "and the auth provider is singleton" do
        let(:authentication_provider) { account.authentication_providers.create!(auth_type: "apple") }

        before do
          account.authentication_providers.create!(auth_type: "apple")
        end

        it { is_expected.to be true }
      end

      context "and the auth provider is not singleton" do
        let(:authentication_provider) { account.authentication_providers.create!(auth_type: "cas") }

        before do
          account.authentication_providers.create!(auth_type: "cas")
        end

        it { is_expected.to be false }
      end
    end
  end

  describe ".find_restorable_provider" do
    subject(:restorable_duplicate) do
      described_class.find_restorable_provider(
        root_account: account,
        auth_type:
      )
    end

    context "when the auth provider is not singleton" do
      let(:auth_type) { "cas" }

      it { is_expected.to be_nil }
    end

    context "when the auth provider is singleton, but not restorable" do
      let(:auth_type) { "apple" }

      it { is_expected.to be_nil }
    end

    context "when the auth provider is singleton and restorable" do
      let(:auth_type) { "apple" }

      before do
        allow(AuthenticationProvider::Apple).to receive_messages(restorable?: true, singleton?: true)
      end

      context "and the account contains a duplicate auth provider" do
        let!(:existing_auth_provider) { account.authentication_providers.create!(auth_type: "apple", workflow_state: "deleted") }

        it "returns the duplicate auth provider" do
          expect(restorable_duplicate).to eq(existing_auth_provider)
        end
      end

      context "and the account does not contain a duplicate auth provider" do
        it { is_expected.to be_nil }
      end
    end
  end

  describe "#destroy" do
    subject(:destroy_authentication_provider) { aac.destroy }

    let!(:aac) { account.authentication_providers.create!(auth_type: "cas") }

    it "retains the database row" do
      aac.destroy
      found = AuthenticationProvider.find(aac.id)
      expect(found).not_to be_nil
    end

    it "sets workflow_state upon destroy" do
      aac.destroy
      aac.reload
      expect(aac.workflow_state).to eq("deleted")
    end

    it "is aliased with #destroy_permanently!" do
      aac.destroy_permanently!
      found = AuthenticationProvider.find(aac.id)
      expect(found).not_to be_nil
    end

    it "soft-deletes associated pseudonyms" do
      user = user_model
      pseudonym = user.pseudonyms.create!(unique_id: "user@facebook.com")
      pseudonym.authentication_provider = aac
      pseudonym.save!
      aac.destroy
      expect(pseudonym.reload.workflow_state).to eq("deleted")
    end

    it "does not call destroy on associated pseudonyms if they're already deleted" do
      user = user_model
      pseudonym = user.pseudonyms.create!(unique_id: "user@facebook.com")
      pseudonym.workflow_state = "deleted"
      pseudonym.authentication_provider = aac
      pseudonym.save!

      expect(pseudonym).not_to receive(:destroy)

      aac.destroy
    end

    context "when the authentication provider is restorable" do
      let!(:pseudonym) do
        user = user_model

        user.pseudonyms.create!(
          unique_id: "user@test.com",
          authentication_provider: aac
        )
      end

      before do
        allow(aac.class).to receive(:restorable?).and_return(true)
      end

      it "does not modify pseudonyms" do
        expect { destroy_authentication_provider }.not_to change { pseudonym.reload.workflow_state }
      end

      it "soft deletes the authentication provider" do
        expect { destroy_authentication_provider }.to change { aac.reload.workflow_state }.from("active").to("deleted")
      end
    end
  end

  describe "#restore" do
    let(:user) { user_model }
    let(:aac) { account.authentication_providers.create!(auth_type: "cas") }
    let(:pseudonym) do
      user.pseudonyms.create!(unique_id: "user@facebook.com", authentication_provider: aac)
    end
    let(:deleted_pseudonym) do
      user.pseudonyms.create!(unique_id: "user@facebook.com",
                              authentication_provider: aac,
                              workflow_state: "deleted",
                              deleted_at: 6.minutes.ago)
    end

    it "restores associated pseudonyms when deleted_at matches provider updated_at" do
      pseudonym
      aac.destroy
      expect { aac.restore }.to change { pseudonym.reload.workflow_state }.to "active"
    end

    it "ignores already deleted pseudonyms" do
      deleted_pseudonym
      aac.destroy
      expect { aac.restore }.not_to change { deleted_pseudonym.reload.workflow_state }
    end

    it "does not restore pseudonyms if deleted_at is nil" do
      pseudonym
      aac.destroy
      pseudonym.update_column(:deleted_at, nil)
      expect { aac.restore }.not_to change { pseudonym.reload.workflow_state }
    end

    it "does not restore pseudonyms if deleted_at does not match provider updated_at" do
      pseudonym
      aac.destroy
      pseudonym.update_column(:deleted_at, 6.minutes.ago)
      expect { aac.restore }.not_to change { pseudonym.reload.workflow_state }
    end
  end

  describe ".active" do
    let!(:aac) { account.authentication_providers.create!(auth_type: "cas") }

    it "finds an aac that isn't deleted" do
      expect(AuthenticationProvider.active).to include(aac)
    end

    it "ignores aacs which have been deleted" do
      aac.destroy
      expect(AuthenticationProvider.active).not_to include(aac)
    end
  end

  describe "list-i-ness" do
    let!(:aac1) { account.authentication_providers.create!(auth_type: "facebook") }
    let!(:aac2) { account.authentication_providers.create!(auth_type: "github") }

    before do
      account.authentication_providers.where(auth_type: "canvas").first.destroy
    end

    it "manages positions automatically within an account" do
      expect(aac1.reload.position).to eq(1)
      expect(aac2.reload.position).to eq(2)
    end

    it "respects deletions for position management" do
      aac3 = account.authentication_providers.create!(auth_type: "google")
      expect(aac2.reload.position).to eq(2)
      aac2.destroy
      expect(aac1.reload.position).to eq(1)
      expect(aac3.reload.position).to eq(2)
    end

    it "moves to bottom of list upon restoration with respect to conflicts" do
      aac3 = account.authentication_providers.create!(auth_type: "cas")
      expect(aac2.reload.position).to eq(2)
      aac2.destroy
      aac2.restore
      expect(aac1.reload.position).to eq(1)
      expect(aac2.reload.position).to eq(2)
      expect(aac3.reload.position).to eq(3)
      aac1.destroy
      aac1.restore
      expect(aac1.reload.position).to eq(3)
    end
  end

  describe "federated_attributes" do
    context "validation" do
      it "normalizes short form" do
        aac = Account.default.authentication_providers.new(auth_type: "saml",
                                                           federated_attributes: { "integration_id" => "internal_id" })
        expect(aac).to be_valid
        expect(aac.federated_attributes).to eq({ "integration_id" => { "attribute" => "internal_id",
                                                                       "provisioning_only" => false } })
      end

      it "defaults provisioning_only to false" do
        aac = Account.default.authentication_providers.new(auth_type: "saml",
                                                           federated_attributes: { "integration_id" => { "attribute" => "internal_id" } })
        expect(aac).to be_valid
        expect(aac.federated_attributes).to eq({ "integration_id" => { "attribute" => "internal_id",
                                                                       "provisioning_only" => false } })
      end

      it "doesn't allow invalid Canvas attributes" do
        aac = Account.default.authentication_providers.new(auth_type: "saml",
                                                           federated_attributes: { "sis_id" => "internal_id" })
        expect(aac).not_to be_valid
      end

      it "allows valid provider attributes" do
        aac = Account.default.authentication_providers.new(auth_type: "saml",
                                                           federated_attributes: { "integration_id" => "internal_id" })
        allow(AuthenticationProvider::SAML).to receive(:recognized_federated_attributes).and_return(["internal_id"])
        expect(aac).to be_valid
      end

      it "doesn't allow invalid provider attributes" do
        aac = Account.default.authentication_providers.new(auth_type: "saml",
                                                           federated_attributes: { "integration_id" => "garbage" })
        allow(AuthenticationProvider::SAML).to receive(:recognized_federated_attributes).and_return(["internal_id"])
        expect(aac).not_to be_valid
      end

      it "rejects unknown keys for attributes" do
        aac = Account.default.authentication_providers.new(auth_type: "saml",
                                                           federated_attributes: { "integration_id" => { "attribute" => "internal_id", "garbage" => "internal_id" } })
        expect(aac).not_to be_valid
      end

      it "requires attribute key for hash attributes" do
        aac = Account.default.authentication_providers.new(auth_type: "saml",
                                                           federated_attributes: { "integration_id" => { "provisioning_only" => true } })
        expect(aac).not_to be_valid
      end

      it "only accepts autoconfirm for email" do
        aac = Account.default.authentication_providers.new(auth_type: "saml",
                                                           federated_attributes: { "email" => { "attribute" => "email", "autoconfirm" => true } })
        expect(aac).to be_valid

        aac = Account.default.authentication_providers.new(auth_type: "saml",
                                                           federated_attributes: { "integration_id" => { "attribute" => "internal_id", "autoconfirm" => true } })
        expect(aac).not_to be_valid
      end
    end
  end

  describe "apply_federated_attributes" do
    let(:aac) do
      Account.default.authentication_providers.new(auth_type: "saml",
                                                   federated_attributes: {
                                                     "admin_roles" => "admin_roles",
                                                     "display_name" => "display_name",
                                                     "email" => "email",
                                                     "given_name" => "given_name",
                                                     "integration_id" => { "attribute" => "internal_id", "provisioning_only" => true },
                                                     "locale" => "locale",
                                                     "name" => "name",
                                                     "sis_user_id" => { "attribute" => "sis_id", "provisioning_only" => true },
                                                     "sortable_name" => "sortable_name",
                                                     "surname" => "surname",
                                                     "time_zone" => "timezone"
                                                   })
    end

    before do
      # ensure the federated_attributes hash is normalized
      aac.valid?
      user_with_pseudonym(active_all: true)
    end

    it "handles most attributes" do
      notification = Notification.create!(name: "Confirm Email Communication Channel", category: "TestImmediately")
      cc = CommunicationChannel.new
      expect(CommunicationChannel).to receive(:new) { |attrs|
        cc.attributes = attrs
        cc
      }
      aac.apply_federated_attributes(@pseudonym,
                                     {
                                       "display_name" => "Mr. Cutler",
                                       "email" => "cody@school.edu",
                                       "internal_id" => "abc123",
                                       "locale" => "es",
                                       "name" => "Cody Cutrer",
                                       "sis_id" => "28",
                                       "sortable_name" => "Cutrer, Cody",
                                       "timezone" => "America/New_York"
                                     },
                                     purpose: :provisioning)
      @user.reload
      expect(cc.messages_sent.keys).to eq [notification.name]
      expect(@user.short_name).to eq "Mr. Cutler"
      expect(@user.communication_channels.email.in_state("unconfirmed").pluck(:path)).to include("cody@school.edu")
      expect(@pseudonym.integration_id).to eq "abc123"
      expect(@user.locale).to eq "es"
      expect(@user.name).to eq "Cody Cutrer"
      expect(@pseudonym.sis_user_id).to eq "28"
      expect(@user.sortable_name).to eq "Cutrer, Cody"
      expect(@user.time_zone.tzinfo.name).to eq "America/New_York"
    end

    it "handles separate names" do
      aac.apply_federated_attributes(@pseudonym,
                                     { "given_name" => "Cody",
                                       "surname" => "Cutrer" })
      @user.reload
      expect(@user.short_name).to eq "Cody Cutrer"
      expect(@user.name).to eq "Cody Cutrer"
      expect(@user.sortable_name).to eq "Cutrer, Cody"
    end

    it "ignores attributes that are for provisioning only when not provisioning" do
      aac.apply_federated_attributes(@pseudonym,
                                     {
                                       "email" => "cody@school.edu",
                                       "internal_id" => "abc123",
                                       "locale" => "es",
                                       "name" => "Cody Cutrer",
                                       "sis_id" => "28",
                                       "sortable_name" => "Cutrer, Cody",
                                       "timezone" => "America/New_York"
                                     })
      @user.reload
      expect(@user.communication_channels.email.in_state("unconfirmed").pluck(:path)).to include("cody@school.edu")
      expect(@pseudonym.integration_id).not_to eq "abc123"
      expect(@user.locale).to eq "es"
      expect(@user.name).to eq "Cody Cutrer"
      expect(@pseudonym.sis_user_id).not_to eq "28"
      expect(@user.sortable_name).to eq "Cutrer, Cody"
      expect(@user.time_zone.tzinfo.name).to eq "America/New_York"
    end

    it "doesn't asplode with nil values" do
      aac.apply_federated_attributes(@pseudonym, { "email" => nil, "surname" => nil, "given_name" => nil })
      expect(@user.name).not_to be_blank
    end

    it "doesn't asplode with an empty email" do
      aac.apply_federated_attributes(@pseudonym, { "email" => "" })
      expect(@user.name).not_to be_blank
    end

    it "ignores empty sis_user_id or integration_id values" do
      @pseudonym.update sis_user_id: "test", integration_id: "testfrd"
      aac.apply_federated_attributes(@pseudonym,
                                     { "sis_id" => "", "internal_id" => "" },
                                     purpose: :provisioning)
      expect(@pseudonym.sis_user_id).to eq "test"
      expect(@pseudonym.integration_id).to eq "testfrd"
    end

    it "ignores conflicting sis_user_id value" do
      @pseudonym.update sis_user_id: "A"
      new_ps = user_with_pseudonym(active_all: true).pseudonym
      aac.apply_federated_attributes(new_ps,
                                     { "sis_id" => "A" },
                                     purpose: :provisioning)
      expect(new_ps.sis_user_id).to be_nil
    end

    it "ignores conflicting integration_id value" do
      @pseudonym.update integration_id: "A"
      new_ps = user_with_pseudonym(active_all: true).pseudonym
      aac.apply_federated_attributes(new_ps,
                                     { "internal_id" => "A" },
                                     purpose: :provisioning)
      expect(new_ps.integration_id).to be_nil
    end

    it "updates the integration_id to match the sis_user_id if requested" do
      @pseudonym.update sis_user_id: "A"
      aac.apply_federated_attributes(@pseudonym,
                                     { "internal_id" => "A" },
                                     purpose: :provisioning)
      expect(@pseudonym.integration_id).to eq "A"
    end

    it "supports multiple emails" do
      aac.apply_federated_attributes(@pseudonym, { "email" => %w[cody@school.edu student@school.edu] })
      @user.reload
      expect(@user.communication_channels.email.pluck(:path)).to eq(%w[nobody@example.com cody@school.edu student@school.edu])
    end

    it "can autoconfirm emails" do
      aac.federated_attributes["email"]["autoconfirm"] = true
      aac.apply_federated_attributes(@pseudonym,
                                     {
                                       "email" => "cody@school.edu",
                                       "internal_id" => "abc123",
                                       "locale" => "es",
                                       "name" => "Cody Cutrer",
                                       "sis_id" => "28",
                                       "sortable_name" => "Cutrer, Cody",
                                       "timezone" => "America/New_York"
                                     })
      @user.reload
      expect(@user.communication_channels.email.in_state("active").pluck(:path)).to include("cody@school.edu")
    end

    it "does not autoconfirm emails for some social providers" do
      aac = AuthenticationProvider::Microsoft.new(federated_attributes: { "email" => { "attribute" => "email", "autoconfirm" => true } })
      aac.apply_federated_attributes(@pseudonym,
                                     {
                                       "email" => "cody@school.edu",
                                       "internal_id" => "abc123",
                                       "locale" => "es",
                                       "name" => "Cody Cutrer",
                                       "sis_id" => "28",
                                       "sortable_name" => "Cutrer, Cody",
                                       "timezone" => "America/New_York"
                                     })
      @user.reload
      expect(@user.communication_channels.email.in_state("unconfirmed").pluck(:path)).to include("cody@school.edu")
    end

    context "admin_roles" do
      it "ignores non-existent roles" do
        aac.apply_federated_attributes(@pseudonym, { "admin_roles" => "garbage" })
        @user.reload
        expect(@user.account_users).not_to be_exists
      end

      it "provisions an admin" do
        aac.apply_federated_attributes(@pseudonym, { "admin_roles" => "AccountAdmin" })
        @user.reload
        aus = @user.account_users.to_a
        expect(aus.length).to eq 1
        expect(aus.first.account).to eq @pseudonym.account
        expect(aus.first.role.name).to eq "AccountAdmin"
      end

      it "doesn't provision an existing admin" do
        @user.account_users.create!(account: @pseudonym.account)
        aac.apply_federated_attributes(@pseudonym, { "admin_roles" => "AccountAdmin" })
        @user.reload
        expect(@user.account_users.count).to eq 1
      end

      it "removes no-longer-extant roles" do
        @user.account_users.create!(account: @pseudonym.account)
        aac.apply_federated_attributes(@pseudonym, { "admin_roles" => "" })
        @user.reload
        expect(@user.account_users.active).not_to be_exists
      end

      it "reactivates previously deleted roles" do
        au = @user.account_users.create!(account: @pseudonym.account)
        au.destroy
        aac.apply_federated_attributes(@pseudonym, { "admin_roles" => "AccountAdmin" })
        @user.reload
        expect(au.reload).to be_active
      end
    end

    context "locale" do
      it "translates _ to -" do
        aac.apply_federated_attributes(@pseudonym, { "locale" => "en_GB" })
        @user.reload
        expect(@user.locale).to eq "en-GB"
      end

      it "follows fallbacks" do
        aac.apply_federated_attributes(@pseudonym, { "locale" => "en-US" })
        @user.reload
        expect(@user.locale).to eq "en"
      end

      it "is case insensitive" do
        aac.apply_federated_attributes(@pseudonym, { "locale" => "en-gb" })
        @user.reload
        expect(@user.locale).to eq "en-GB"
      end

      it "supports multiple incoming values, selecting the first available match" do
        allow(I18n).to receive(:available_locales).and_return(%w[fr en])
        aac.apply_federated_attributes(@pseudonym, { "locale" => %w[ab-CD fr-FR] })
        @user.reload
        expect(@user.locale).to eq "fr"
      end
    end
  end

  describe "#provision_user" do
    let(:auth_provider) { account.authentication_providers.create!(auth_type: "microsoft", tenant: "microsoft", login_attribute: "sub") }

    it "works" do
      p = auth_provider.provision_user("unique_id")
      expect(p.unique_id).to eq "unique_id"
      expect(p.login_attribute).to eq "sub"
      expect(p.unique_ids).to eq({})
    end

    it "handles a hash of unique ids" do
      p = auth_provider.provision_user("sub" => "unique_id", "tid" => "abc")
      expect(p.unique_id).to eq "unique_id"
      expect(p.login_attribute).to eq "sub"
      expect(p.unique_ids).to eq({ "sub" => "unique_id", "tid" => "abc" })
    end
  end

  context "otp_via_sms" do
    let(:aac) do
      account.authentication_providers.new(auth_type: "canvas")
    end

    it "defaults to true" do
      expect(aac.otp_via_sms?).to be_truthy
    end

    it "can opt out" do
      aac.update! settings: { otp_via_sms: false }
      expect(aac.otp_via_sms?).to be_falsey
    end

    it "can opt back in" do
      aac.update! settings: { otp_via_sms: true }
      expect(aac.otp_via_sms?).to be_truthy
    end
  end
end
