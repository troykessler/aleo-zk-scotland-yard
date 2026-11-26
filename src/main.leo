const MAP_MERKLE_ROOT_DEPTH: u8 = 9; // 2**9 = max 512 unique connections per map

const MISTERX_TICKETS_TAXI: u8 = 4;
const MISTERX_TICKETS_BUS: u8 = 3;
const MISTERX_TICKETS_UNDERGROUND: u8 = 3;
const MISTERX_TICKETS_CONCEALED: u8 = 4;
const MISTERX_TICKETS_DOUBLE_MOVE: u8 = 2;

const GAME_DETECTIVES: u8 = 4;

const DETECTIVE_TICKETS_TAXI: u8 = 10;
const DETECTIVE_TICKETS_BUS: u8 = 8;
const DETECTIVE_TICKETS_UNDERGROUND: u8 = 4;

const MAX_MOVES: u8 = 24;

const STARTING_POSITIONS: [u8; 18] = [13, 26, 29, 34, 50, 53, 91, 94, 103, 112, 117, 132, 138, 141, 155, 174, 197, 198];

struct Player {
    addr: address,

    // probably worth moving this to separate mappings
    position_trace: [u8; MAX_MOVES + 1],
    ticket_trace: [u8; MAX_MOVES],

    tickets_taxi: u8,
    tickets_bus: u8,
    tickets_underground: u8,
    tickets_concealed: u8,
    tickets_double_move: u8,

    // for misterx if he is caught by detectives,
    // for detectives if they are out of moves
    lost: bool,
}

struct Game {
    map_id: u64,

    misterx: Player,
    detectives: [Player; 4],
}

fn is_in_starting_positions(position: u8) -> bool {
    for i in 0u8..18u8 {
        if STARTING_POSITIONS[i] == position {
            return true;
        }
    }

    return false;
}

fn get_merkle_root(
    leaf_index: u16,
    merkle_proof: [field; MAP_MERKLE_ROOT_DEPTH],
    from_position: u8,
    to_position: u8,
    transport_mask: u8,
) -> field {
    let low = from_position < to_position ? from_position : to_position;
    let high = from_position < to_position ? to_position : from_position;

    let current_hash = Poseidon4::hash_to_field([low, high, transport_mask]);

    let index = leaf_index;

    for i in 0u8..MAP_MERKLE_ROOT_DEPTH {
        let is_left = (index % 2u16) == 0u16;

        let left = is_left ? current_hash : merkle_proof[i];
        let right = is_left ? merkle_proof[i] : current_hash;

        current_hash = Poseidon4::hash_to_field([left, right]);
        index = index / 2u16;
    }

    // assert that provided leaf_index was indeed below 512
    assert_eq(index, 0u16);
    
    return current_hash;
}

program scotlandyard.aleo {
    storage game_counter: u64;
    storage map_counter: u64;

    mapping games: u64 => Game;
    mapping maps: u64 => field;

    record MisterXTrace {
        owner: address,
        game_id: u64,

        position_trace: [u8; MAX_MOVES + 1],
    }
    
    @custom
    constructor() {
        if std::ctx::edition() > 0u16 {
            assert_eq(std::ctx::program_owner(), aleo1s04xz7v48t8jyf5kyzv5f080ctm3wfcrv0ezk2u0l863q79neuxsv2yg9n);
        }
    }

    fn publish_map(public map_root: field) -> Final {
        let caller: address = std::ctx::caller();

        assert_eq(caller, aleo1s04xz7v48t8jyf5kyzv5f080ctm3wfcrv0ezk2u0l863q79neuxsv2yg9n);

        return final {
            let map_id: u64 = map_counter.unwrap_or(0u64);
            maps.set(map_id, map_root);
            map_counter = map_id + 1;
        };
    }

    fn create_game(unverified_game_id: u64, misterx_start_position: u8, public map_id: u64, public detective: address) -> (MisterXTrace, Final) {
        let misterx: address = std::ctx::caller();
        assert_neq(misterx, detective);

        let misterx_position_trace = [0u8; MAX_MOVES + 1];
        misterx_position_trace[0u8] = misterx_start_position;

        let misterx_trace = MisterXTrace {
            owner: misterx,
            game_id: unverified_game_id,

            position_trace: [0u8; MAX_MOVES + 1],
        };

        return (
            misterx_trace,
            final {
                let game_id: u64 = game_counter.unwrap_or(0u64);
                assert_eq(unverified_game_id, game_id);

                assert(maps.contains(map_id));

                games.set(game_id, Game {
                    map_id,

                    misterx: Player {
                        addr: misterx,

                        position_trace: [0u8; MAX_MOVES + 1],
                        ticket_trace: [0u8; MAX_MOVES],

                        tickets_taxi: MISTERX_TICKETS_TAXI,
                        tickets_bus: MISTERX_TICKETS_BUS,
                        tickets_underground: MISTERX_TICKETS_UNDERGROUND,
                        tickets_concealed: MISTERX_TICKETS_CONCEALED,
                        tickets_double_move: MISTERX_TICKETS_DOUBLE_MOVE,

                        lost: false,
                    },
                    detectives: [Player {
                        addr: detective,

                        position_trace: [0u8; MAX_MOVES + 1],
                        ticket_trace: [0u8; MAX_MOVES],

                        tickets_taxi: DETECTIVE_TICKETS_TAXI,
                        tickets_bus: DETECTIVE_TICKETS_BUS,
                        tickets_underground: DETECTIVE_TICKETS_UNDERGROUND,
                        tickets_concealed: 0u8,
                        tickets_double_move: 0u8,

                        lost: false,
                    }; 4],
                });

                game_counter = game_id + 1;
            }
        );
    }

    fn move_misterx(
        public game_id: u64,
        public unverified_game: Game,
        misterx_trace: MisterXTrace,
        leaf_index: u16,
        merkle_proof: [field; MAP_MERKLE_ROOT_DEPTH],
        to_position: u8,
        transport_mask: u8,
        public ticket: u8,
    ) -> (MisterXTrace, Final) {
        let misterx: address = std::ctx::caller();

        assert_eq(game_id, misterx_trace.game_id);

        let from_position = 0u8;
        let position_idx = 0u8;

        for i in 0u8..MAX_MOVES {
            if misterx_trace.position_trace[i] > 0u8 {
                from_position = misterx_trace.position_trace[i];
                position_idx = i;
            }
        }

        assert(position_idx < MAX_MOVES);

        let misterx_lost = false;

        for d in 0u8..GAME_DETECTIVES {
            let detective_position = 0u8;

            for i in 0u8..MAX_MOVES {
                if i == position_idx {
                    detective_position = unverified_game.detectives[d].position_trace[i];

                    misterx_lost = misterx_lost || detective_position == from_position;
                    misterx_lost = misterx_lost || detective_position == to_position;
                }
            }
        }

        assert(ticket == 1u8 || ticket == 2u8 || ticket == 4u8 || ticket == 8u8);
        assert((transport_mask & ticket) != 0u8);

        let merkle_root = get_merkle_root(
            leaf_index,
            merkle_proof,
            from_position,
            to_position,
            transport_mask,
        );

        let updated_position_trace = misterx_trace.position_trace;

        for i in 0u8..MAX_MOVES + 1u8 {
            if i == position_idx + 1u8 {
                updated_position_trace[i] = to_position;
            }
        }

        let updated_misterx_trace = MisterXTrace {
            owner: misterx_trace.owner,
            game_id: misterx_trace.game_id,

            position_trace: updated_position_trace,
        };

        let misterx_position_trace = misterx_lost ? updated_position_trace : unverified_game.misterx.position_trace;

        return (
            updated_misterx_trace,
            final {
                assert(games.contains(game_id));

                let game = games.get(game_id);
                assert_eq(game, unverified_game);

                assert_eq(maps.get_or_use(game.map_id, 0field), merkle_root);

                game.misterx.position_trace = misterx_position_trace;

                for i in 0u8..MAX_MOVES {
                    game.misterx.ticket_trace[i] = i == position_idx ? ticket : game.misterx.ticket_trace[i];
                }

                game.misterx.tickets_taxi = game.misterx.tickets_taxi - (ticket == 1u8 ? 1u8 : 0u8);
                game.misterx.tickets_bus = game.misterx.tickets_bus - (ticket == 2u8 ? 1u8 : 0u8);
                game.misterx.tickets_underground = game.misterx.tickets_underground - (ticket == 4u8 ? 1u8 : 0u8);
                game.misterx.tickets_concealed = game.misterx.tickets_concealed - (ticket == 8u8 ? 1u8 : 0u8);
                // how to handle double use tickets?

                games.set(game_id, game);
            }
        );
    }
}
