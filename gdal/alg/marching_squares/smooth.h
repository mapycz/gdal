#ifndef MARCHING_SQUARE_SMOOTH_H
#define MARCHING_SQUARE_SMOOTH_H

#include <vector>

namespace marching_squares {

template <typename Appender>
struct Smooth
{
    Smooth(Appender & appender,
           unsigned smoothCycles,
           unsigned lookAhead,
           unsigned minPoints,
           bool processLoops,
           double slide)
        : appender_(appender),
          smoothCycles_(smoothCycles),
          lookAhead_(lookAhead),
          minPoints_(minPoints),
          processLoops_(processLoops),
          slide_(slide)
    {}

    void addLine(double level, LineString & ls, bool closed)
    {
        if (smoothCycles_) {
            if (!closed) {
                closed = isClosed(ls);
            }
            if (!shouldProcess(ls, closed)) {
                return;
            }

            std::vector<Point> points(removePussies(ls, closed));

            for (unsigned i = 0; i < smoothCycles_; ++i) {
                smooth(points, closed);
            }

            ls.assign(points.begin(), points.end());
        }

        appender_.addLine(level, ls, closed);
    }

private:
    bool shouldProcess(const LineString & ls, bool closed) const
    {
        return minPoints_ <= 1 || !closed || ls.size() >= minPoints_;
    }

    bool isClosed(const LineString & ls) const {
        return ls.size() > 2 &&
            ls.front().x == ls.back().x &&
            ls.front().y == ls.back().y;
    }

    void smooth(std::vector<Point> & points, bool closed)
    {
        const std::size_t n = points.size();

        if (lookAhead_ >= n || lookAhead_ < 2) {
            return;
        }

        const bool isLoop = processLoops_ && closed;
        const std::size_t half = lookAhead_ / 2;
        const std::size_t count = isLoop ? (n + half) : (n - half);

        Point acc(0, 0);
        for (std::size_t i = 0; i < lookAhead_; ++i) {
            acc.x += points[i].x;
            acc.y += points[i].y;
        }

        std::vector<Point> res(n + half);
        const double sc = 1.0 / lookAhead_;
        for (std::size_t i = half; i < count; i++) {
            std::size_t index = smoothingIndex(i, n, isLoop);
            res[i].x = (points[index].x * (1.0 - slide_)) + (acc.x * sc * slide_);
            res[i].y = (points[index].y * (1.0 - slide_)) + (acc.y * sc * slide_);

            if ((i + half + 1 < n) || isLoop) {
                index = smoothingIndex(i - half, n, isLoop);
                acc.x -= points[index].x;
                acc.y -= points[index].y;

                index = smoothingIndex(i + half + 1, n, isLoop);
                acc.x += points[index].x;
                acc.y += points[index].y;
            }
        }

        if (isLoop) {
            for (std::size_t i = 0; i < half; i++)
            {
                points[i] = res[n + i - 1];
            }
            for (std::size_t i = half; i < n; i++)
            {
                points[i] = res[i];
            }
        } else {
            for (std::size_t i = half; i < n - half; i++)
            {
                points[i] = res[i];
            }
        }
    }

    std::size_t smoothingIndex(std::size_t index, std::size_t count, bool isLoop)
    {
        return isLoop ? index % (count - 1) : index;
    }

    std::vector<Point> removePussies(LineString & ls, bool closed) const
    {
        if (closed || ls.size() < 4) {
            return std::vector<Point>(ls.begin(), ls.end());
        }

        auto begin = ls.begin();
        auto end = ls.end();
        ++begin;
        --end;

        return std::vector<Point>(begin, end);
    }

    Appender & appender_;
    const unsigned smoothCycles_;
    const unsigned lookAhead_;
    const unsigned minPoints_;
    const bool processLoops_;
    const double slide_;
};

}
#endif
