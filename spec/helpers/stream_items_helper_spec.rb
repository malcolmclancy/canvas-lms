# frozen_string_literal: true

#
# Copyright (C) 2012 - present Instructure, Inc.
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

describe StreamItemsHelper do
  before :once do
    Notification.create!(name: "Assignment Created", category: "TestImmediately")
    course_with_teacher(active_all: true)
    @reviewee_student = course_with_student(active_all: true, course: @course).user
    @reviewer_student = course_with_student(active_all: true, course: @course).user
    @other_user = user_factory
    @another_user = user_factory

    @context = @course
    @discussion = discussion_topic_model
    entry = @discussion.discussion_entries.new(user_id: @other_user, message: "you've been mentioned for pretend")
    entry.mentions.new(user_id: @teacher, root_account_id: @discussion.root_account_id)
    entry.save!
    @announcement = announcement_model
    @assignment = assignment_model(course: @course, peer_reviews: true)
    assessor_submission1 = @assignment.submit_homework(@reviewer_student, body: "submission text")
    assessor_submission2 = @assignment.submit_homework(@teacher, body: "submission text")
    submission1 = submission_model(assignment: @assignment, user: @reviewee_student)
    submission2 = submission_model(assignment: @assignment, user: @student)
    AssessmentRequest.create!(
      assessor: @reviewer_student,
      assessor_asset: assessor_submission1,
      asset: submission1,
      user: @reviewee_student
    )
    AssessmentRequest.create!(
      assessor: @teacher,
      assessor_asset: assessor_submission2,
      asset: submission2,
      user: @student
    )
    # this conversation will not be shown, since the teacher is the last author
    conversation(@another_user, @teacher).conversation.add_message(@teacher, "zomg")
    # whereas this one will be shown
    @participant = conversation(@other_user, @teacher)
    @conversation = @participant.conversation
  end

  context "categorize_stream_items" do
    it "categorizes different types correctly" do
      @items = @teacher.recent_stream_items
      expect(@items.size).to eq 7 # 1 for each type, 1 hidden conversation
      @categorized = helper.categorize_stream_items(@items, @teacher)
      expect(@categorized["Announcement"].size).to eq 1
      expect(@categorized["Conversation"].size).to eq 1
      expect(@categorized["Assignment"].size).to eq 1
      expect(@categorized["DiscussionTopic"].size).to eq 1
      expect(@categorized["DiscussionEntry"].size).to eq 1
      expect(@categorized["AssessmentRequest"].size).to eq 1
    end

    it "normalizes output into common fields" do
      @items = @teacher.recent_stream_items
      expect(@items.size).to eq 7 # 1 for each type, 1 hidden conversation
      @categorized = helper.categorize_stream_items(@items, @teacher)
      @categorized.values.flatten.each do |presenter|
        item = @items.detect { |si| si.id == presenter.stream_item_id }
        expect(item).not_to be_nil
        expect(presenter.updated_at).not_to be_nil
        expect(presenter.path).not_to be_nil
        expect(presenter.context).not_to be_nil
        expect(presenter.summary).not_to be_nil
      end
    end

    it "skips items that are not visible to the current user" do
      # this discussion topic will not be shown since it is a graded discussion with a
      # future unlock at date
      @group_assignment_discussion = group_assignment_discussion({ course: @course })
      @group_assignment_discussion.update_attribute(:user, @teacher)
      assignment = @group_assignment_discussion.assignment
      assignment.update({
                          due_at: 30.days.from_now,
                          lock_at: 30.days.from_now,
                          unlock_at: 20.days.from_now
                        })
      expect(@student.recent_stream_items).not_to include @group_assignment_discussion
      expect(@teacher.recent_stream_items).not_to include @group_assignment_discussion
    end

    it "skips assessment requests the user doesn't have permission to read" do
      @items = @reviewer_student.recent_stream_items
      @categorized = helper.categorize_stream_items(@items, @reviewer_student)
      expect(@categorized["AssessmentRequest"].size).to eq 1
      @assignment.peer_reviews = false
      @assignment.save!
      AdheresToPolicy::Cache.clear
      @items = @reviewer_student.recent_stream_items
      @categorized = helper.categorize_stream_items(@items, @reviewer_student)
      expect(@categorized["AssessmentRequest"].size).to eq 0
    end

    context "across shards" do
      specs_require_sharding

      it "stream item ids should always be relative to the user's shard" do
        course_with_teacher(active_all: 1)
        @user2 = @shard1.activate { user_model }
        @course.enroll_student(@user2).accept!
        @course.discussion_topics.create!(title: "title")

        items = @user2.recent_stream_items
        categorized = helper.categorize_stream_items(items, @user2)
        categorized1 = @shard1.activate { helper.categorize_stream_items(items, @user2) }
        categorized2 = @shard2.activate { helper.categorize_stream_items(items, @user2) }
        si_id = @shard1.activate { items[0].id }
        expect(categorized["DiscussionTopic"][0].stream_item_id).to eq si_id
        expect(categorized1["DiscussionTopic"][0].stream_item_id).to eq si_id
        expect(categorized2["DiscussionTopic"][0].stream_item_id).to eq si_id
      end

      it "links to stream item assets should be relative to the active shard" do
        @shard1.activate { course_with_teacher(account: Account.create, active_all: 1) }
        @shard2.activate { course_with_teacher(account: Account.create, active_all: 1, user: @teacher) }
        topic = @course.discussion_topics.create!(title: "title")

        items = @teacher.recent_stream_items
        categorized = helper.categorize_stream_items(items, @teacher)
        categorized1 = @shard1.activate { helper.categorize_stream_items(items, @teacher) }
        categorized2 = @shard2.activate { helper.categorize_stream_items(items, @teacher) }
        expect(categorized["DiscussionTopic"][0].path).to eq "/courses/#{Shard.short_id_for(@course.global_id)}/discussion_topics/#{Shard.short_id_for(topic.global_id)}"
        expect(categorized1["DiscussionTopic"][0].path).to eq "/courses/#{Shard.short_id_for(@course.global_id)}/discussion_topics/#{Shard.short_id_for(topic.global_id)}"
        expect(categorized2["DiscussionTopic"][0].path).to eq "/courses/#{@course.local_id}/discussion_topics/#{topic.local_id}"
      end

      it "links to stream item contexts should be relative to the active shard" do
        @shard1.activate { course_with_teacher(account: Account.create, active_all: 1) }
        @shard2.activate { course_with_teacher(account: Account.create, active_all: 1, user: @teacher) }
        @course.discussion_topics.create!(title: "title")

        items = @teacher.recent_stream_items
        categorized = helper.categorize_stream_items(items, @teacher)
        categorized1 = @shard1.activate { helper.categorize_stream_items(items, @teacher) }
        categorized2 = @shard2.activate { helper.categorize_stream_items(items, @teacher) }
        expect(categorized["DiscussionTopic"][0].context.linked_to).to eq "/courses/#{Shard.short_id_for(@course.global_id)}/discussion_topics"
        expect(categorized1["DiscussionTopic"][0].context.linked_to).to eq "/courses/#{Shard.short_id_for(@course.global_id)}/discussion_topics"
        expect(categorized2["DiscussionTopic"][0].context.linked_to).to eq "/courses/#{@course.local_id}/discussion_topics"
      end
    end
  end

  context "extract_path" do
    it "links to correct place" do
      @items = @teacher.recent_stream_items
      expect(@items.size).to eq 7 # 1 for each type, 1 hidden conversation
      @categorized = helper.categorize_stream_items(@items, @teacher)
      expect(@categorized["Announcement"].first.path).to match("/courses/#{@course.id}/announcements/#{@announcement.id}")
      expect(@categorized["Conversation"].first.path).to match("/conversations/#{@conversation.id}")
      expect(@categorized["Assignment"].first.path).to match("/courses/#{@course.id}/assignments/#{@assignment.id}")
      expect(@categorized["DiscussionTopic"].first.path).to match("/courses/#{@course.id}/discussion_topics/#{@discussion.id}")
      expect(@categorized["DiscussionEntry"].first.path).to match("/courses/#{@course.id}/discussion_topics/#{@discussion.id}?entry_id=#{DiscussionEntry.last.id}")
      expect(@categorized["AssessmentRequest"].first.path).to match("/courses/#{@course.id}/assignments/#{@assignment.id}/submissions/#{@student.id}")
    end

    it "provides correct link for AssessmentRequest when assignments_2_student feature flag is enabled" do
      @course.enable_feature!(:assignments_2_student)
      @items = @teacher.recent_stream_items
      @categorized = helper.categorize_stream_items(@items, @teacher)
      expect(@categorized["AssessmentRequest"].first.path).to match("/courses/#{@course.id}/assignments/#{@assignment.id}?reviewee_id=#{@student.id}")
    end
  end

  context "extract_context" do
    it "finds the correct context" do
      @items = @teacher.recent_stream_items
      expect(@items.size).to eq 7 # 1 for each type, 1 hidden conversation
      @categorized = helper.categorize_stream_items(@items, @teacher)
      expect(@categorized["Announcement"].first.context.id).to eq @course.id
      expect(@categorized["Conversation"].first.context.id).to eq @other_user.id
      expect(@categorized["Assignment"].first.context.id).to eq @course.id
      expect(@categorized["DiscussionTopic"].first.context.id).to eq @course.id
      expect(@categorized["DiscussionEntry"].first.context.id).to eq @course.id
      expect(@categorized["AssessmentRequest"].first.context.id).to eq @course.id
    end
  end

  context "extract_updated_at" do
    it "finds the correct updated_at time for a conversation participant" do
      @conversation.updated_at = 1.hour.ago
      @conversation.save!

      @items = @teacher.recent_stream_items
      @categorized = helper.categorize_stream_items(@items, @teacher)
      @convo_participant = @conversation.conversation_participants.find_by(user: @teacher)
      @stream_item_updated_at = @categorized["Conversation"].first.updated_at
      expect(@stream_item_updated_at).not_to eq @conversation.updated_at
      expect(@stream_item_updated_at).to eq @convo_participant.last_message_at
    end
  end

  context "extract_summary" do
    it "finds the right content" do
      @items = @teacher.recent_stream_items
      expect(@items.size).to eq 7 # 1 for each type, 1 hidden conversation
      @categorized = helper.categorize_stream_items(@items, @teacher)
      expect(@categorized["Announcement"].first.summary).to eq @announcement.title
      expect(@categorized["Conversation"].first.summary).to eq @participant.last_message.body
      expect(@categorized["Assignment"].first.summary).to match(/Assignment Created/)
      expect(@categorized["DiscussionTopic"].first.summary).to eq @discussion.title
      expect(@categorized["DiscussionEntry"].first.summary).to eq "#{@other_user.short_name} mentioned you in #{@discussion.title}."
      expect(@categorized["AssessmentRequest"].first.summary).to include(@assignment.title)
    end

    it "handles anonymous review for AssessmentRequests" do
      @assignment.update_attribute(:anonymous_peer_reviews, true)
      student = @student
      create_enrollments(@course, [@other_user])
      assessor_submission = submission_model(assignment: @assignment, user: @other_user)
      assessment_request = AssessmentRequest.create!(
        assessor: @other_user,
        asset: @submission,
        user: student,
        assessor_asset: assessor_submission
      )
      assessment_request.workflow_state = "assigned"
      assessment_request.save
      items = @other_user.recent_stream_items
      @categorized = helper.categorize_stream_items(items, @other_user)
      expect(@categorized["AssessmentRequest"].first.summary).to include("Anonymous User")
    end

    it "anonymizes path for anonymous AssessmentRequests" do
      @assignment.update_attribute(:anonymous_peer_reviews, true)
      student = @student
      create_enrollments(@course, [@other_user])
      assessor_submission = @assignment.submit_homework(@other_user, body: "submission text")
      assessment_request = AssessmentRequest.create!(
        assessor: @other_user,
        asset: @submission,
        user: student,
        assessor_asset: assessor_submission
      )
      assessment_request.workflow_state = "assigned"
      assessment_request.save
      items = @other_user.recent_stream_items
      @categorized = helper.categorize_stream_items(items, @other_user)
      expect(@categorized["AssessmentRequest"].first.path).to include("anonymous_submission")
    end
  end
end
