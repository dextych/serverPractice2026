import { Stand } from '../../services/stand.js';
import { catchAsync } from '../../infrastructure/errors/catchAsync.js';
export const getStatus = catchAsync(async (req, res) => {
    const data = await Stand.getStatus();
    return res.status(200).json(data);
});