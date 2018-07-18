#define GAMETICKER_PREGAME_TIME 180

var/global/datum/controller/gameticker/ticker
var/global/datum/lobby_music_player/lobby_music_player = null

/datum/controller/gameticker
	var/const/restart_timeout = 300
	var/current_state = GAME_STATE_PREGAME
	var/admin_started = FALSE

//	var/hide_mode = FALSE
//	var/datum/game_mode/mode = null
	var/post_game = FALSE
	var/event_time = null
	var/event = FALSE

	var/login_music			// music played in pregame lobby

	var/list/datum/mind/minds = list()//The people in the game. Used for objective tracking.

	var/random_players = FALSE 	// if set to nonzero, ALL players who latejoin or declare-ready join will have random appearances/genders

	var/list/syndicate_coalition = list() // list of traitor-compatible factions
	var/list/factions = list()			  // list of all factions
	var/list/availablefactions = list()	  // list of factions with openings

	var/pregame_timeleft = FALSE

	var/delay_end = FALSE	//if set to nonzero, the round will not restart on it's own

//	var/triai = FALSE//Global holder for Triumvirate

	var/round_end_announced = FALSE // Spam Prevention. Announce round end only once.

	var/can_latejoin_ruforce = TRUE
	var/can_latejoin_geforce = TRUE

	var/players_can_join = TRUE

	var/tip = null
	var/maytip = TRUE

	var/finished = FALSE // set to TRUE by the map object

	var/restarting_is_very_bad = FALSE

/datum/controller/gameticker/proc/pregame()

	spawn (0)

		current_state = GAME_STATE_PREGAME // just in case

		if (!lobby_music_player)
			lobby_music_player = new

		login_music = lobby_music_player.get_song()

		do
			pregame_timeleft = GAMETICKER_PREGAME_TIME
			maytip = TRUE

			if (serverswap_open_status)
				world << "<b><span style = 'notice'>Welcome to the pre-game lobby!</span></b>"
				world << "The game will start in [pregame_timeleft] seconds."

			while (current_state == GAME_STATE_PREGAME)
				for (var/i=0, i<10, i++)
					sleep(1)
					vote.process()
				if (round_progressing)
					pregame_timeleft--
				if (pregame_timeleft == config.vote_autogamemode_timeleft)
					if (!vote.time_remaining)
						vote.autogamemode()	//Quit calling this over and over and over and over.
						while (vote.time_remaining)
							for (var/i=0, i<10, i++)
								sleep(1)
								vote.process()
				if (pregame_timeleft == 20)
					if (tip)
						world << "<span class = 'notice'><b>Tip of the round:</b> [tip]</span>"
					else
						var/list/tips = file2list("config/tips.txt")
						if (tips.len)
							if (serverswap_open_status)
								world << "<span class = 'notice'><b>Tip of the round:</b> [pick(tips)]</span>"
								qdel_list(tips)
					maytip = FALSE
				if (pregame_timeleft <= 0)
					current_state = GAME_STATE_SETTING_UP
					/* if we were force started, still show the tip */
					if (maytip)
						if (tip)
							world << "<span class = 'notice'><b>Tip of the round:</b> [tip]</span>"
						else
							var/list/tips = file2list("config/tips.txt")
							if (tips.len)
								if (serverswap_open_status)
									world << "<span class = 'notice'><b>Tip of the round:</b> [pick(tips)]</span>"
									qdel_list(tips)
		while (!setup())


/datum/controller/gameticker/proc/setup()

	current_state = GAME_STATE_PLAYING

	job_master.ResetOccupations()

	if (!map || !map.can_start() && !admin_started)
		if (serverswap_open_status)
			world << "<b>Unable to start the game.</b> Not enough players, [map.required_players] active players needed. Reverting to the pre-game lobby."
		current_state = GAME_STATE_PREGAME
		job_master.ResetOccupations()
		return FALSE

	create_characters() //Create player characters and transfer them
	collect_minds()
	equip_characters()
//	data_core.manifest()

	// trains setup before roundstart hooks called because SS train ladders rely on it
	if (map.uses_main_train)
		setup_trains()
		train_loop()

	TOD_loop()

	callHook("roundstart")

	spawn(0)//Forking here so we dont have to wait for this to finish
//		mode.post_setup()
		//Cleanup some stuff
		for (var/obj/effect/landmark/start/S in landmarks_list)
			//Deleting Startpoints but we need the ai point to AI-ize people later
			if (S.name != "AI")
				qdel(S)

	//	world << "<span class = 'notice'><b>Enjoy the game!</b></FONT>"
		//Holiday Round-start stuff	~Carn

		// todo: make these hooks. Apparently they all fail on /hook/roundstart
		setup_autobalance()
		reinforcements_master = new


	//close_jobs()//Makes certain jobs unselectable past roundstart. Unneeded atm.
	//start_events() //handles random events and space dust.
	//new random event system is handled from the MC.

	/* TODO: discord bot - Kachnov
	var/admins_number = 0
	for (var/client/C)
		if (C.holder)
			admins_number++

	if (admins_number == 0)
		send2adminirc("Round has started with no admins online.")*/

	return TRUE

/datum/controller/gameticker/proc/close_jobs()
	for (var/datum/job/job in job_master.occupations)
		if (job.title == "Captain")
			job.total_positions = FALSE

/datum/controller/gameticker/proc/create_characters()
	for (var/mob/new_player/player in player_list)
		if (player && player.ready && player.mind)
			if (!player.mind.assigned_role)
				continue
			else
				player.create_character()
				qdel(player)


/datum/controller/gameticker/proc/collect_minds()
	for (var/mob/living/player in player_list)
		if (player.mind)
			ticker.minds += player.mind

/datum/controller/gameticker/proc/equip_characters()
	for (var/mob/living/carbon/human/player in player_list)
		if (player && player.mind && player.mind.assigned_role)
		//	if (!player_is_antag(player.mind, only_offstation_roles = TRUE))
			job_master.EquipRank(player, player.mind.assigned_role, FALSE)
		//		equip_custom_items(player)

/datum/controller/gameticker/proc/process()
	if (current_state != GAME_STATE_PLAYING)
		return FALSE

//		mode.process()

//		emergency_shuttle.process() //handled in scheduler
/*
	var/game_finished = FALSE
	var/mode_finished = FALSE
	if (config.continous_rounds)
		game_finished = (mode.station_was_nuked)
		mode_finished = (!post_game && mode.check_finished())
	else
		game_finished = (mode.check_finished())
		mode_finished = game_finished
*/
	if (finished)
		current_state = GAME_STATE_FINISHED

/*		spawn
			declare_completion()*/

		spawn(50)

			callHook("roundend")

			var/restart_after = restart_timeout

			// give time for the other server to restart
			if (processes.mapswap)
				if (processes.mapswap.finished_at == -1)
					restart_after = 1200 + (vote.time_remaining * 10)
				else
					var/n = world.time - processes.mapswap.finished_at
					if (n <= 900)
						restart_after = 1200 - n

			var/next_map = processes.mapswap ? processes.mapswap.next_map_title : "TBD"
			if (vote && vote.mode == "map" && vote.time_remaining > 0)
				next_map = "TBD"


			if (!delay_end)
				world << "<span class='notice'><big>Restarting in [round(restart_after/10)] seconds. Next map: <b>[next_map]</b></big></span>"
				if (restart_after > restart_timeout)
					restarting_is_very_bad = TRUE
					spawn (restart_after - restart_timeout)
						restarting_is_very_bad = FALSE

			if (!delay_end)
				sleep(restart_after)
				if (!delay_end)
					world.Reboot()
				else
					world << "<span class='notice'><b>An admin has delayed the round end.</b></span>"
			else
				world << "<span class='notice'><b>An admin has delayed the round end.</b></span>"

	return TRUE
