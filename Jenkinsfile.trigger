// one job per arch (for now) that triggers builds for all unbuilt images
properties([
	disableConcurrentBuilds(),
	disableResume(),
	durabilityHint('PERFORMANCE_OPTIMIZED'),
	pipelineTriggers([
		upstream(threshold: 'UNSTABLE', upstreamProjects: 'meta'),
	]),
])

env.BASHBREW_ARCH = env.JOB_NAME.split('/')[-1].minus('trigger-') // "windows-amd64", "arm64v8", etc

def queue = []
def breakEarly = false // thanks Jenkins...

// this includes the number of attempts per failing buildId
// { buildId: { "count": 1, ... }, ... }
def pastFailedJobsJson = '{}'

node {
	stage('Checkout') {
		checkout(scmGit(
			userRemoteConfigs: [[
				url: 'https://github.com/docker-library/meta.git',
				name: 'origin',
			]],
			branches: [[name: '*/main']],
			extensions: [
				submodule(
					parentCredentials: true,
					recursiveSubmodules: true,
					trackingSubmodules: true,
				),
				cleanBeforeCheckout(),
				cleanAfterCheckout(),
				[$class: 'RelativeTargetDirectory', relativeTargetDir: 'meta'],
			],
		))
		pastFailedJobsJson = sh(returnStdout: true, script: '''#!/usr/bin/env bash
			set -Eeuo pipefail -x

			if ! json="$(wget --timeout=5 -qO- "$JOB_URL/lastSuccessfulBuild/artifact/pastFailedJobs.json")"; then
				echo >&2 'failed to get pastFailedJobs.json'
				json='{}'
			fi
			jq <<<"$json" '.'
		''').trim()
	}

	dir('meta') {
		def queueJson = ''
		stage('Queue') {
			withEnv([
				'pastFailedJobsJson=' + pastFailedJobsJson,
			]) {
				// using pastFailedJobsJson, sort the needs_build queue so that failing builds always live at the bottom of the queue
				queueJson = sh(returnStdout: true, script: '''
					jq -L.scripts '
						include "meta";
						(env.pastFailedJobsJson | fromjson) as $pastFailedJobs
						| [
							.[]
							| select(
								needs_build
								and (
									.build.arch as $arch
									| if env.BASHBREW_ARCH == "gha" then
										[ "amd64", "i386", "windows-amd64" ]
									else [ env.BASHBREW_ARCH ] end
									| index($arch)
								)
							)
						]
						# this Jenkins job exports a JSON file that includes the number of attempts so far per failing buildId so that this can sort by attempts which means failing builds always live at the bottom of the queue (sorted by the number of times they have failed, so the most failing is always last)
						| sort_by($pastFailedJobs[.buildId].count // 0)
					' builds.json
				''').trim()
			}
		}
		if (queueJson && queueJson != '[]') {
			queue = readJSON(text: queueJson)
			currentBuild.displayName = 'queue size: ' + queue.size() + ' (#' + currentBuild.number + ')'
		} else {
			currentBuild.displayName = 'empty queue (#' + currentBuild.number + ')'
			breakEarly = true
			return
		}

		// for GHA builds, we still need a node (to curl GHA API), so we'll handle those here
		if (env.BASHBREW_ARCH == 'gha') {
			withCredentials([
				string(
					variable: 'GH_TOKEN',
					credentialsId: 'github-access-token-docker-library-bot-meta',
				),
			]) {
				for (buildObj in queue) {
					def identifier = buildObj.source.arches[buildObj.build.arch].tags[0] + ' (' + buildObj.build.arch + ')'
					def json = writeJSON(json: buildObj, returnText: true)
					withEnv([
						'json=' + json,
					]) {
						stage(identifier) {
							echo(json) // for debugging/data purposes

							sh '''#!/usr/bin/env bash
								set -Eeuo pipefail -x

								# https://docs.github.com/en/free-pro-team@latest/rest/actions/workflows?apiVersion=2022-11-28#create-a-workflow-dispatch-event
								payload="$(
									jq <<<"$json" -L.scripts '
										include "jenkins";
										gha_payload
									'
								)"

								set +x
								curl -fL \
									-X POST \
									-H 'Accept: application/vnd.github+json' \
									-H "Authorization: Bearer $GH_TOKEN" \
									-H 'X-GitHub-Api-Version: 2022-11-28' \
									https://api.github.com/repos/docker-library/meta/actions/workflows/build.yml/dispatches \
									-d "$payload"
							'''
						}
					}
				}
			}
			// we're done triggering GHA, so we're completely done with this job
			breakEarly = true
			return
		}
	}
}

if (breakEarly) { return } // thanks Jenkins...

// now that we have our parsed queue, we can release the node we're holding up (since we handle GHA builds above)
def pastFailedJobs = readJSON(text: pastFailedJobsJson)
def newFailedJobs = [:]

for (buildObj in queue) {
	def identifier = buildObj.source.arches[buildObj.build.arch].tags[0]
	def json = writeJSON(json: buildObj, returnText: true)
	withEnv([
		'json=' + json,
	]) {
		stage(identifier) {
			echo(json) // for debugging/data purposes

			def res = build(
				job: 'build-' + env.BASHBREW_ARCH,
				parameters: [
					string(name: 'buildId', value: buildObj.buildId),
				],
				propagate: false,
				quietPeriod: 5, // seconds
			)
			// TODO do something useful with "res.result" (especially "res.result != 'SUCCESS'")
			echo(res.result)
			if (res.result != 'SUCCESS') {
				def c = 1
				if (pastFailedJobs[buildObj.buildId]) {
					// TODO more defensive access of .count? (it is created just below, so it should be safe)
					c += pastFailedJobs[buildObj.buildId].count
				}
				// TODO maybe implement some amount of backoff? keep first url/endTime?
				newFailedJobs[buildObj.buildId] = [
					count: c,
					identifier: identifier,
					url: res.absoluteUrl,
					endTime: (res.startTimeInMillis + res.duration) / 1000.0, // convert to seconds
				]

				// "catchError" is the only way to set "stageResult" :(
				catchError(message: 'Build of "' + identifier + '" failed', buildResult: 'UNSTABLE', stageResult: 'FAILURE') { error() }
			}
		}
	}
}

// save newFailedJobs so we can use it next run as pastFailedJobs
node {
	def newFailedJobsJson = writeJSON(json: newFailedJobs, returnText: true)
	withEnv([
		'newFailedJobsJson=' + newFailedJobsJson,
	]) {
		stage('Archive') {
			dir('builds') {
				deleteDir()
				sh '''#!/usr/bin/env bash
					set -Eeuo pipefail -x

					jq <<<"$newFailedJobsJson" '.' | tee pastFailedJobs.json
				'''
				archiveArtifacts(
					artifacts: '*.json',
					fingerprint: true,
					onlyIfSuccessful: true,
				)
			}
		}
	}
}
