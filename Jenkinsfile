#!/usr/bin/env groovy

pipeline {
  agent any

  environment {
    RELEASE_NAME = 'job_applications_bot'
    BOT_NAME = 'job_applications'
    STATE_NAME = 'bots.job_applications'
    SALT_TARGET = '-G bot_army_node_type:air'
    GH_REPO = 'anthropics/elixir_bots'
  }

  stages {
    stage('Compile') {
      steps {
        sh '''
          cd elixir_bots/bot_army_job_applications
          mix compile --warnings-as-errors
        '''
      }
    }

    stage('Test') {
      steps {
        sh '''
          cd elixir_bots/bot_army_job_applications
          mix test --cover
        '''
      }
    }

    stage('Release') {
      when {
        branch 'main'
      }
      steps {
        sh '''
          cd elixir_bots/bot_army_job_applications
          mix release
        '''
      }
    }

    stage('Publish') {
      when {
        branch 'main'
      }
      steps {
        sh '''
          cd elixir_bots/bot_army_job_applications
          RELEASE_VSN=$(cat _build/prod/rel/job_applications_bot/releases/RELEASES | tail -1 | awk '{print $1}')
          echo "Release version: $RELEASE_VSN"

          # Create tarball
          tar -czf job_applications_bot-$RELEASE_VSN.tar.gz \
            -C _build/prod/rel \
            job_applications_bot/

          # Publish to GitHub releases
          gh release create "job_applications_bot/v$RELEASE_VSN" \
            job_applications_bot-$RELEASE_VSN.tar.gz \
            --repo "$GH_REPO" \
            --title "Job Applications Bot v$RELEASE_VSN" \
            --notes "Automated release from Jenkins" \
            || true
        '''
      }
    }

    stage('Deploy') {
      when {
        branch 'main'
      }
      steps {
        sh '''
          # Helper function for Salt with retries
          salt_apply() {
            local state=$1
            local attempt=0
            until sudo /opt/salt/salt ${SALT_TARGET} state.apply $state; do
              attempt=$((attempt + 1))
              if [ $attempt -ge 3 ]; then
                echo "Failed to apply Salt state: $state"
                return 1
              fi
              echo "Retrying Salt state: $state (attempt $((attempt + 1))/3)"
              sleep 30
            done
          }

          # Apply core states first
          salt_apply common.core
          salt_apply common.schemas

          # Apply bot-specific state
          salt_apply ${STATE_NAME}

          # Always restart service — Salt 'unless' guard doesn't reliably restart
          sudo launchctl unload /Library/LaunchDaemons/com.botarmy.${BOT_NAME}.plist 2>/dev/null || true
          sleep 2
          sudo launchctl load -w /Library/LaunchDaemons/com.botarmy.${BOT_NAME}.plist

          echo "Deployment complete for ${BOT_NAME}"
        '''
      }
    }
  }

  post {
    failure {
      echo "Pipeline failed for ${BOT_NAME}"
    }
    success {
      echo "Pipeline succeeded for ${BOT_NAME}"
    }
  }
}
