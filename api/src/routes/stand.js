import { getTopology } from '../controllers/stand/getTopology.js';
import { getStatus } from '../controllers/stand/getStatus.js';

export default [
    {
        path: '/stand/topology',
        verb: 'get',
        handler: getTopology,
        authedOnly: false,
    },
    {
        path: '/stand/status',
        verb: 'get',
        handler: getStatus,
        authedOnly: false,
    },
];