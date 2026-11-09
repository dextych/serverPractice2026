import { Stand } from '../../services/stand.js';
import { catchAsync } from '../../infrastructure/errors/catchAsync.js';

export const getTopology = catchAsync(async (req, res) => {
    const data = await Stand.getTopology();
    return res.status(200).json(data);
});