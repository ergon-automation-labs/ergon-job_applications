pipeline {
  // Download releases from GitHub and deploy them
  agent { label 'built-in' }

  options {
    timeout(time: 30, unit: 'MINUTES')
    timestamps()
  }

  triggers {
    // Poll GitHub every 5 minutes for new commits
    pollSCM('H/5 * * * *')
  }

  environment {
    BOT_NAME = 'job_applications'
    RELEASE_NAME = 'bot_army_job_applications'
    STATE_NAME = 'bot_army_job_applications'
    RELEASE_DIR = "/opt/ergon/releases/${BOT_NAME}"
    GITHUB_REPO = "ergon-automation-labs/ergon-job_applications"
    SALT_TARGET = '-G bot_army_node_type:air'
  }

  stages {

    stage('Checkout') {
      steps {
        checkout scm
      }
    }

    stage('Download Build Artifact') {
      steps {
        sh '''
          echo "==============================================="
          echo "Downloading pre-built release from GitHub"
          echo "==============================================="

          # Get the latest published release (not a draft)
          LATEST_RELEASE=$(gh api repos/${GITHUB_REPO}/releases \
            -q '.[] | select(.draft==false) | .tag_name' | head -1)

          if [ -z "$LATEST_RELEASE" ]; then
            echo "ERROR: No published release found on GitHub"
            exit 1
          fi

          echo "Latest release: $LATEST_RELEASE"

          # Download the tarball asset
          echo "Downloading: ${RELEASE_NAME}-*.tar.gz"
          mkdir -p ./release-artifact

          gh release download $LATEST_RELEASE \
            --repo ${GITHUB_REPO} \
            --pattern "*.tar.gz" \
            -D ./release-artifact

          echo "✓ Release downloaded successfully"

          # Extract tarball
          cd ./release-artifact
          TARBALL=$(ls -1 *.tar.gz | head -1)
          echo "Extracting: $TARBALL"
          tar -xzf "$TARBALL"
          rm "$TARBALL"
          ls -la
          cd ..
        '''
      }
    }

    stage('Deploy') {
      steps {
        sh '''
          echo "==============================================="
          echo "Deploying release"
          echo "==============================================="
          echo "Start time: $(date)"

          TIMESTAMP=$(date +%Y%m%d%H%M%S)
          DEST="${RELEASE_DIR}/releases/${TIMESTAMP}"

          echo "Creating release directory..."
          mkdir -p "${DEST}"

          echo "Copying release artifacts..."
          cp -r ./release-artifact/* "${DEST}/"

          echo "Updating current symlink..."
          ln -sfn "${DEST}" "${RELEASE_DIR}/current"

          echo "Deploying service via Salt..."
          echo "⚠️  NOTE: Salt state files must be synced from bot_army_infra before this runs."
          echo "    Run: cd ../bot_army_infra && make sync-bots"
          echo ""

          salt_apply() {
            local state=$1 attempt=0
            until sudo /opt/salt/salt ${SALT_TARGET} state.apply $state; do
              attempt=$((attempt + 1))
              if [ $attempt -ge 3 ]; then echo "salt state.apply $state failed after 3 attempts"; return 1; fi
              echo "Salt busy, retrying in 30s... (attempt $attempt/3)"
              sleep 30
            done
          }
          # Apply dependencies first
          salt_apply common.core
          salt_apply common.schemas
          # Then apply the bot state
          salt_apply bots.${STATE_NAME}

          echo "Restarting service to pick up new release..."
          sudo launchctl unload /Library/LaunchDaemons/com.botarmy.${BOT_NAME}.plist 2>/dev/null || true
          sleep 2
          sudo launchctl load -w /Library/LaunchDaemons/com.botarmy.${BOT_NAME}.plist

          echo "Checking service health..."
          /opt/bot_army/scripts/health_check.sh ${BOT_NAME}

          echo "Deploy complete!"
          echo "Completion time: $(date)"
        '''
      }
    }

    stage('Run Migrations') {
      steps {
        sh '''
          echo "==============================================="
          echo "Running database migrations"
          echo "==============================================="

          # Get the release binary path
          RELEASE_BIN="${RELEASE_DIR}/current/${RELEASE_NAME}/bin/${RELEASE_NAME}"

          if [ ! -f "$RELEASE_BIN" ]; then
            echo "⚠️  Release binary not found at $RELEASE_BIN"
            echo "Skipping migrations (may already be at correct schema)"
            exit 0
          fi

          # Run migrations using the release
          echo "Running: $RELEASE_BIN eval 'BotArmyJobApplications.Release.migrate()'"

          $RELEASE_BIN eval 'BotArmyJobApplications.Release.migrate()' || {
            echo "⚠️  Migration failed or Release module not found"
            echo "Continuing with deployment (manual migration may be needed)"
          }

          echo "✓ Migrations complete"
        '''
      }
    }

    stage('Sync Job Boards to Salt') {
      steps {
        sh '''
          echo "==============================================="
          echo "Syncing job boards to Salt pillar"
          echo "==============================================="

          # Check if bot_army_infra sibling directory exists
          if [ ! -d "../bot_army_infra" ]; then
            echo "⚠️  bot_army_infra not available (may be first run)"
            echo "Skipping board sync (will use existing Salt configuration)"
            exit 0
          fi

          cd ..

          # Run board discovery and sync
          echo "Discovering active job boards..."
          cd bot_army_job_applications
          bash ../scripts/mise-exec.sh mix job_applications.sync_boards_to_salt || {
            echo "⚠️  Board sync failed, but continuing"
            exit 0
          }

          # If pillar was updated, commit and push to bot_army_infra
          cd ../bot_army_infra
          if git diff --quiet salt/pillar/job_applications.sls 2>/dev/null; then
            echo "No board changes detected"
          else
            echo "Board configuration changed, pushing to bot_army_infra..."
            git add salt/pillar/job_applications.sls
            git commit -m "Auto-sync: update job board configuration from job_applications discovery"
            git push origin main || echo "⚠️  Push to bot_army_infra failed (non-blocking)"
          fi

          cd ../bot_army_job_applications
          echo "✓ Board sync complete"
        '''
      }
    }

  }

  post {
    success {
      sh '''
        # Extract version from the deployed release
        START_ERL="${RELEASE_DIR}/current/${RELEASE_NAME}/releases/start_erl.data"
        if [ -f "$START_ERL" ]; then
          VERSION=$(awk '{print $2}' "$START_ERL")
        else
          VERSION="unknown"
        fi

        # Extract release timestamp and git SHA
        TIMESTAMP=$(basename $(readlink "${RELEASE_DIR}/current"))
        GIT_SHA=$(git rev-parse --short HEAD 2>/dev/null || echo "unknown")

        # Build JSON payload
        PAYLOAD=$(cat <<EOF
{"bot":"${BOT_NAME}","node":"air","triggered_by":"jenkins","status":"success","version":"${VERSION}","release":"${TIMESTAMP}","sha":"${GIT_SHA}"}
EOF
)
        echo "📢 Notifying NATS of successful deployment..."
        /opt/bot_army/scripts/nats_publish.sh ops.builds.${BOT_NAME} "$PAYLOAD" || echo "⚠️  NATS notification failed (non-blocking)"
      '''
    }
    failure {
      sh '''
        # Build JSON payload for failure
        PAYLOAD=$(cat <<EOF
{"bot":"${BOT_NAME}","node":"air","triggered_by":"jenkins","status":"failed"}
EOF
)
        echo "📢 Notifying NATS of failed deployment..."
        /opt/bot_army/scripts/nats_publish.sh ops.builds.${BOT_NAME} "$PAYLOAD" || echo "⚠️  NATS notification failed (non-blocking)"
      '''
    }
    always {
      cleanWs()
    }
  }
}
